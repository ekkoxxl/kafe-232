#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\..\infra\remote-deploy\Kafe.Deployment\Kafe.Deployment.psd1'
Import-Module $modulePath -Force -ErrorAction Stop
$module = Get-Module Kafe.Deployment
$expected = @('Get-KafeDeploymentState', 'Start-KafeUpload', 'Send-KafeChunk', 'Publish-KafeUpload', 'Invoke-KafeRollback') | Sort-Object
$actual = @(Get-Command -Module Kafe.Deployment | Select-Object -ExpandProperty Name | Sort-Object)
if (($actual -join ',') -cne ($expected -join ',')) { throw 'The module exports an unexpected command.' }
$role = Import-PowerShellDataFile (Join-Path (Split-Path $modulePath -Parent) 'RoleCapabilities\KafePublisher.psrc')
if ((@($role.VisibleFunctions | Sort-Object) -join ',') -cne ($expected -join ',') -or
    @($role.VisibleCmdlets).Count -ne 0 -or @($role.VisibleExternalCommands).Count -ne 0 -or
    @($role.VisibleAliases).Count -ne 0 -or @($role.VisibleProviders).Count -ne 0) { throw 'The JEA role exposes an unexpected capability.' }
Write-Output 'PASS five-command export and JEA role allowlist'

# Private pure validators are tested through the trusted module scope. No JEA endpoint,
# server configuration, credentials, IIS, service or database is created or changed.
& $module {
    function Expect-KafeRejection([string] $Label, [scriptblock] $Action, [string] $Code) {
        try { & $Action; throw 'TEST_UNEXPECTED_ACCEPTANCE' }
        catch {
            if ($_.Exception.Message -notlike ('KAFE_' + $Code + '*')) { throw }
            Write-Output ('PASS rejects ' + $Label)
        }
    }
    $sensitiveMarker = 'do-not-log-private-value'
    $diagnosticError = New-Object Management.Automation.ErrorRecord(
        (New-Object InvalidOperationException $sensitiveMarker),
        $sensitiveMarker, [Management.Automation.ErrorCategory]::InvalidOperation, $sensitiveMarker)
    $safeDiagnostic = Get-KafeSafeErrorInfo $diagnosticError
    if (($safeDiagnostic | ConvertTo-Json -Compress).Contains($sensitiveMarker) -or
        $safeDiagnostic.FullyQualifiedErrorId -cne 'Other' -or $safeDiagnostic.ErrorType -cne 'System.InvalidOperationException') {
        throw 'Safe error diagnostics included an unapproved message, target or FQID.'
    }
    Write-Output 'PASS safe error metadata excludes exception message, target and custom error ID'
    $sender = [pscustomobject]@{
        ConnectionString = 'https://100.126.247.75:5986/wsman'
        UserInfo = [pscustomobject]@{ Identity = [pscustomobject]@{ Name = 'MACHINE\kafepublisher' } }
    }
    if ((Assert-KafeTransport $sender) -cne 'machine\kafepublisher') { throw 'Authenticated HTTPS transport not recognized.' }
    $sender.ConnectionString = 'http://100.126.247.75:5985/wsman'
    Expect-KafeRejection 'HTTP remoting transport' { Assert-KafeTransport $sender } 'HttpsTailnetTransportRequired'
    $sender.ConnectionString = 'https://example.com:5986/wsman'
    Expect-KafeRejection 'non-tailnet transport' { Assert-KafeTransport $sender } 'HttpsTailnetTransportRequired'
    $sender.ConnectionString = 'https://100.126.247.75:5986/wsman?unexpected=1'
    Expect-KafeRejection 'transport query' { Assert-KafeTransport $sender } 'HttpsTailnetTransportRequired'

    $sha = 'a' * 40; $hash = 'b' * 64
    $run = [pscustomobject]@{
        id = [long]12345678901; repository = [pscustomobject]@{ id = [long]1431509368; owner = [pscustomobject]@{ id = [long]68338579 } }
        head_repository = [pscustomobject]@{ id = [long]1431509368 }; workflow_id = [long]399837899
        path = '.github/workflows/ci.yml@refs/heads/main'; head_branch = 'main'; event = 'push'; status = 'completed'; conclusion = 'success'; head_sha = $sha
    }
    $artifact = [pscustomobject]@{
        id = [long]12345678902; name = 'kafe-web-' + $sha; expired = $false; size_in_bytes = [long]120
        digest = 'sha256:' + $hash
        workflow_run = [pscustomobject]@{ id = [long]12345678901; repository_id = [long]1431509368; head_repository_id = [long]1431509368; head_branch = 'main'; head_sha = $sha }
    }
    $main = [pscustomobject]@{ object = [pscustomobject]@{ sha = $sha } }
    Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120
    Write-Output 'PASS trusted CI push metadata including 64-bit run and artifact IDs'
    $run.event = 'pull_request'
    Expect-KafeRejection 'pull-request artifact provenance' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedCiRun'
    $run.event = 'push'; $run.head_repository.id = 99
    Expect-KafeRejection 'fork repository identity' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedCiRun'
    $run.head_repository.id = [long]1431509368; $main.object.sha = 'c' * 40
    Expect-KafeRejection 'stale main commit' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedCiRun'
    $main.object.sha = $sha; $artifact.digest = $null
    Expect-KafeRejection 'missing original ZIP digest' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedArtifact'
    $artifact.digest = 'sha256:' + ('d' * 64)
    Expect-KafeRejection 'different original ZIP digest' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedArtifact'
    $artifact.digest = 'sha256:' + $hash; $artifact.expired = $true
    Expect-KafeRejection 'expired artifact' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedArtifact'
    $artifact.expired = $false; $run.workflow_id = 1
    Expect-KafeRejection 'unapproved workflow identity' { Assert-KafeArtifactMetadata $run $artifact $main $sha 12345678901 12345678902 $hash 120 } 'UnapprovedCiRun'

    Add-Type -AssemblyName System.IO.Compression
    function New-TestArchive([object[]] $Entries) {
        $memory = New-Object IO.MemoryStream
        $zip = New-Object IO.Compression.ZipArchive($memory, [IO.Compression.ZipArchiveMode]::Create, $true)
        foreach ($item in $Entries) {
            $entry = $zip.CreateEntry([string]$item.Name)
            if ($item.PSObject.Properties.Name -contains 'Attributes') { $entry.ExternalAttributes = [int]$item.Attributes }
            $stream = $entry.Open()
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$item.Content)
            $stream.Write($bytes, 0, $bytes.Length); $stream.Dispose()
        }
        $zip.Dispose(); $memory.Position = 0
        return ,$memory
    }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('kafe-zip-tests-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($temporaryRoot)
    function Test-ZipRejection([string] $Label, [object[]] $Entries, [string] $Code) {
        $stream = New-TestArchive $Entries
        $destination = Join-Path $temporaryRoot ([guid]::NewGuid().ToString('N'))
        try { Expect-KafeRejection $Label { Expand-KafeArchiveSafely $stream $destination } $Code }
        finally { $stream.Dispose() }
    }
    try {
        $originalRoot = $script:KafeRoot
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            $script:KafeRoot = $temporaryRoot
            $null = [IO.Directory]::CreateDirectory((Join-Path $temporaryRoot 'state'))
            $configurationPath = Join-Path $temporaryRoot 'state\remote-deploy.json'
            $configuration = @{
                SchemaVersion = 1; Repository = $script:KafeRepository; RepositoryId = $script:KafeRepositoryId
                WorkflowPath = $script:KafeWorkflowPath; DeploymentRoot = $temporaryRoot; SmokeUser = 'MACHINE-I\kafesmoke'
            }
            foreach ($culture in @('en-US', 'tr-TR')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                [IO.File]::WriteAllText($configurationPath, ($configuration | ConvertTo-Json))
                $null = Get-KafeConfiguration
                Write-Output ('PASS ASCII smoke identity under ' + $culture)
            }
            $configuration.SmokeUser = 'MACHINE-I\KAFESMOKE'
            [IO.File]::WriteAllText($configurationPath, ($configuration | ConvertTo-Json))
            Expect-KafeRejection 'noncanonical smoke account suffix under tr-TR' { Get-KafeConfiguration } 'ServerConfigurationRejected'
            $configuration.SmokeUser = 'MACHINE-' + [char]0x0130 + '\kafesmoke'
            [IO.File]::WriteAllText($configurationPath, ($configuration | ConvertTo-Json))
            Expect-KafeRejection 'non-ASCII smoke hostname under tr-TR' { Get-KafeConfiguration } 'ServerConfigurationRejected'
        }
        finally { $script:KafeRoot = $originalRoot; [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
        $stream = New-TestArchive @([pscustomobject]@{ Name = 'Views/Home/Index.cshtml'; Content = 'normal web content' })
        $destination = Join-Path $temporaryRoot 'normal'
        try { Expand-KafeArchiveSafely $stream $destination } finally { $stream.Dispose() }
        if ([IO.File]::ReadAllText((Join-Path $destination 'Views\Home\Index.cshtml')) -cne 'normal web content') { throw 'Normal ZIP contents did not extract.' }
        Write-Output 'PASS bounded normal ZIP extraction'
        Test-ZipRejection 'ZIP directory traversal' @([pscustomobject]@{ Name = '../escape.txt'; Content = 'x' }) 'ArchivePathRejected'
        Test-ZipRejection 'ZIP alternate data stream' @([pscustomobject]@{ Name = 'Web.config:stream'; Content = 'x' }) 'ArchivePathRejected'
        Test-ZipRejection 'ZIP Windows backslash path' @([pscustomobject]@{ Name = 'Views\escape.txt'; Content = 'x' }) 'ArchivePathRejected'
        Test-ZipRejection 'ZIP reserved Windows device' @([pscustomobject]@{ Name = 'NUL.txt'; Content = 'x' }) 'ArchivePathRejected'
        $originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($culture in @('en-US', 'tr-TR')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                Test-ZipRejection ('ZIP case-insensitive duplicate under ' + $culture) @([pscustomobject]@{ Name = 'Web.config'; Content = 'x' }, [pscustomobject]@{ Name = 'web.CONFIG'; Content = 'y' }) 'ArchiveDuplicatePath'
            }
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture }
        Test-ZipRejection 'ZIP symlink entry' @([pscustomobject]@{ Name = 'link'; Content = 'elsewhere'; Attributes = (0xA000 -shl 16) }) 'ArchiveLinkRejected'
        $oldEntryBytes = $script:KafeMaxEntryBytes; $oldExpandedBytes = $script:KafeMaxExpandedBytes; $oldEntries = $script:KafeMaxEntries
        try {
            $script:KafeMaxEntryBytes = 3
            Test-ZipRejection 'ZIP individual expanded byte limit' @([pscustomobject]@{ Name = 'file.txt'; Content = '1234' }) 'ArchiveSizeLimit'
            $script:KafeMaxEntryBytes = $oldEntryBytes; $script:KafeMaxExpandedBytes = 5
            Test-ZipRejection 'ZIP total expanded byte limit' @([pscustomobject]@{ Name = 'a.txt'; Content = '123' }, [pscustomobject]@{ Name = 'b.txt'; Content = '123' }) 'ArchiveSizeLimit'
            $script:KafeMaxExpandedBytes = $oldExpandedBytes; $script:KafeMaxEntries = 1
            Test-ZipRejection 'ZIP entry count limit' @([pscustomobject]@{ Name = 'a.txt'; Content = 'x' }, [pscustomobject]@{ Name = 'b.txt'; Content = 'x' }) 'ArchiveEntryLimit'
        }
        finally { $script:KafeMaxEntryBytes = $oldEntryBytes; $script:KafeMaxExpandedBytes = $oldExpandedBytes; $script:KafeMaxEntries = $oldEntries }
        if ([IO.File]::Exists((Join-Path $temporaryRoot 'escape.txt'))) { throw 'Traversal wrote outside its extraction destination.' }
    }
    finally {
        # Only the exact, newly created test directory below the system temp root is removed.
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'kafe-zip-tests-*') { throw 'Test cleanup path rejected.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output 'All remote deployment validator tests passed; no server or IIS settings changed.'
