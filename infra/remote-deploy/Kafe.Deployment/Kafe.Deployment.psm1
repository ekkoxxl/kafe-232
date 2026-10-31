#requires -Version 5.1
Set-StrictMode -Version Latest
Import-Module Microsoft.PowerShell.Utility -Scope Local -ErrorAction Stop
Import-Module Microsoft.PowerShell.Security -Scope Local -ErrorAction Stop
$script:KafeRoot = 'C:\KafeDemo'
$script:KafeRepository = 'OrcunUcuncu/kafe-232'
$script:KafeRepositoryId = [long]1431509368
$script:KafeOwnerId = [long]68338579
$script:KafeWorkflowId = [long]399837899
$script:KafeWorkflowPath = '.github/workflows/ci.yml'
$script:KafeTransportHost = '100.126.247.75'
$script:KafeChunkBytes = 196608
$script:KafeMaxArchiveBytes = 50MB
$script:KafeMaxExpandedBytes = 200MB
$script:KafeMaxEntryBytes = 100MB
$script:KafeMaxEntries = 5000

function Stop-KafeOperation([string] $Code) {
    $exception = New-Object InvalidOperationException ('KAFE_' + $Code)
    $exception.Data['KafeCode'] = $Code
    throw $exception
}

function Assert-KafeTransport($SenderInfo) {
    if ($null -eq $SenderInfo) { Stop-KafeOperation 'RemoteSessionRequired' }
    $uri = $null
    if (-not [uri]::TryCreate([string]$SenderInfo.ConnectionString, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.Port -ne 5986 -or $uri.DnsSafeHost -cne $script:KafeTransportHost -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        Stop-KafeOperation 'HttpsTailnetTransportRequired'
    }
    $caller = [string]$SenderInfo.UserInfo.Identity.Name
    if ([string]::IsNullOrWhiteSpace($caller) -or $caller -match '[\r\n\x00]') { Stop-KafeOperation 'AuthenticatedCallerRequired' }
    return $caller.ToLowerInvariant()
}

function Get-KafeCaller {
    $senderInfo = Get-Variable -Name PSSenderInfo -ValueOnly -ErrorAction SilentlyContinue
    return (Assert-KafeTransport $senderInfo)
}

function Assert-KafeNoReparse([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-KafeOperation 'ReparsePathRejected' }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory }
        else { $item = $item.Parent }
    }
}

function Get-KafeConfiguration {
    Assert-KafeNoReparse $script:KafeRoot
    $configurationPath = Join-Path $script:KafeRoot 'state\remote-deploy.json'
    Assert-KafeNoReparse $configurationPath
    $configuration = Get-Content -LiteralPath $configurationPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($configuration.SchemaVersion -ne 1 -or $configuration.Repository -cne $script:KafeRepository -or
        [long]$configuration.RepositoryId -ne $script:KafeRepositoryId -or
        $configuration.WorkflowPath -cne $script:KafeWorkflowPath -or
        $configuration.DeploymentRoot -cne $script:KafeRoot -or
        [string]$configuration.SmokeUser -cnotmatch '^[A-Za-z0-9._-]+\\kafesmoke$') {
        Stop-KafeOperation 'ServerConfigurationRejected'
    }
    return $configuration
}

function Write-KafeAudit([string] $Event, [string] $Code = '', [string] $UploadId = '', [long] $CiRunId = 0, [long] $ArtifactId = 0, [hashtable] $ErrorInfo = $null) {
    # Only fixed event/reason codes and validated numeric/GUID identifiers are logged.
    $record = @{ utc = [DateTime]::UtcNow.ToString('o'); event = $Event; code = $Code }
    if ($UploadId -match '^[0-9a-f]{32}$') { $record.uploadId = $UploadId }
    if ($CiRunId -gt 0) { $record.ciRunId = $CiRunId }
    if ($ArtifactId -gt 0) { $record.artifactId = $ArtifactId }
    if ($null -ne $ErrorInfo) {
        foreach ($field in @('ErrorType', 'HResult', 'InnerErrorType', 'InnerHResult', 'ScriptLineNumber', 'ScriptName', 'FullyQualifiedErrorId', 'CommandName')) {
            if ($ErrorInfo.ContainsKey($field)) { $record[$field] = $ErrorInfo[$field] }
        }
    }
    $auditPath = Join-Path $script:KafeRoot 'state\remote-deploy-audit.jsonl'
    [IO.File]::AppendAllText($auditPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

function Get-KafeSafeErrorInfo($ErrorRecord) {
    # No exception message, command text, arguments, source line, stack, target object,
    # file path or invocation position message may enter this audit record.
    $info = @{
        ErrorType = 'Other'; HResult = [int]$ErrorRecord.Exception.HResult
        ScriptLineNumber = 0; ScriptName = 'Other'; FullyQualifiedErrorId = 'Other'
    }
    $typeName = $ErrorRecord.Exception.GetType().FullName
    if ($typeName -cmatch '^(System|Microsoft\.PowerShell)\.[A-Za-z0-9_.+]{1,150}$') { $info.ErrorType = $typeName }
    if ($null -ne $ErrorRecord.Exception.InnerException) {
        $inner = $ErrorRecord.Exception.InnerException
        $innerType = $inner.GetType().FullName
        if ($innerType -cmatch '^(System|Microsoft\.PowerShell)\.[A-Za-z0-9_.+]{1,150}$') { $info.InnerErrorType = $innerType }
        $info.InnerHResult = [int]$inner.HResult
    }
    if ($null -ne $ErrorRecord.InvocationInfo) {
        $lineNumber = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
        if ($lineNumber -ge 0 -and $lineNumber -le 100000) { $info.ScriptLineNumber = $lineNumber }
        $scriptName = [IO.Path]::GetFileName([string]$ErrorRecord.InvocationInfo.ScriptName)
        if ($scriptName -cin @('Kafe.Deployment.psm1', 'Deploy-Iis.ps1', 'Rollback-Iis.ps1')) { $info.ScriptName = $scriptName }
    }
    # Only known engine IDs are retained; a custom FQID can contain arbitrary text.
    $engineId = ([string]$ErrorRecord.FullyQualifiedErrorId).Split(',')[0]
    $allowedIds = @(
        'CommandNotFoundException', 'Modules_ModuleNotFound', 'Modules_ImportModuleError',
        'InvokeMethodOnNull', 'PropertyNotFoundStrict', 'PropertyNotFound', 'MethodNotFound',
        'MethodInvocationException', 'InvalidOperation', 'InvalidOperationException',
        'ParameterBindingFailed', 'NamedParameterNotFound', 'PositionalParameterNotFound',
        'AmbiguousParameterSet', 'ParameterArgumentValidationError',
        'ParameterArgumentValidationErrorNullNotAllowed', 'CannotFindPath', 'PathNotFound',
        'UnauthorizedAccess', 'UnauthorizedAccessException', 'System.UnauthorizedAccessException',
        'System.InvalidOperationException', 'System.IO.IOException',
        'Microsoft.PowerShell.Commands.WriteErrorException'
    )
    if ($engineId -cin $allowedIds) { $info.FullyQualifiedErrorId = $engineId }
    if ($ErrorRecord.Exception -is [Management.Automation.CommandNotFoundException]) {
        $command = [string]$ErrorRecord.Exception.CommandName
        $knownCommands = @(
            'Get-FullDirectory', 'Assert-NoReparsePoint', 'Assert-ChildPath', 'Test-Package',
            'Get-HttpStatus', 'Test-RunningRelease', 'Restart-DeploymentPool',
            'Set-StrictMode', 'Get-Item', 'Get-Content', 'Get-ChildItem', 'Get-FileHash',
            'Microsoft.PowerShell.Utility\Get-FileHash', 'ConvertFrom-Json', 'ConvertTo-Json',
            'Test-Path', 'Where-Object', 'New-Object', 'Join-Path', 'Import-Module',
            'Set-ItemProperty', 'Get-Website', 'Get-WebAppPoolState', 'Restart-WebAppPool',
            'Start-WebAppPool', 'Get-WebsiteState', 'Start-Website',
            'Get-WebConfigurationProperty', 'Copy-Item', 'New-Item', 'Set-Acl',
            'Write-Warning', 'Start-Sleep', 'Get-Date', 'Get-Variable', 'Get-KafeSmokeCredential'
        )
        $info.CommandName = 'Other'
        if ($command -cin $knownCommands) { $info.CommandName = $command }
    }
    return $info
}

function Write-KafeFailure([string] $Operation, $ErrorRecord) {
    $code = 'UnexpectedFailure'
    if ($ErrorRecord.Exception.Data.Contains('KafeCode')) { $code = [string]$ErrorRecord.Exception.Data['KafeCode'] }
    try { Write-KafeAudit ($Operation + 'Failed') $code -ErrorInfo (Get-KafeSafeErrorInfo $ErrorRecord) } catch { }
    throw (New-Object InvalidOperationException ('KAFE_' + $code + ': operation failed; the administrator can inspect the deployment audit.'))
}

function Get-KafeApiObject([string] $Resource) {
    # Resource strings are constructed only by trusted module code, never remote parameters.
    $uri = 'https://api.github.com/repos/' + $script:KafeRepository + '/' + $Resource
    try {
        return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 25 -UseBasicParsing -ErrorAction Stop -Headers @{
            Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'KafeDeployment/1.0'
        }
    }
    catch { Stop-KafeOperation 'GitHubMetadataUnavailable' }
}

function Assert-KafeArtifactMetadata($Run, $Artifact, $MainRef, [string] $CommitSha, [long] $CiRunId, [long] $ArtifactId, [string] $ArchiveSha256, [long] $ArchiveBytes) {
    if ([long]$Run.id -ne $CiRunId -or [long]$Run.repository.id -ne $script:KafeRepositoryId -or
        [long]$Run.repository.owner.id -ne $script:KafeOwnerId -or
        [long]$Run.head_repository.id -ne $script:KafeRepositoryId -or
        [long]$Run.workflow_id -ne $script:KafeWorkflowId -or
        ([string]$Run.path).Split('@')[0] -cne $script:KafeWorkflowPath -or
        $Run.head_branch -cne 'main' -or $Run.event -cne 'push' -or
        $Run.status -cne 'completed' -or $Run.conclusion -cne 'success' -or
        $Run.head_sha -ine $CommitSha -or $MainRef.object.sha -ine $CommitSha) {
        Stop-KafeOperation 'UnapprovedCiRun'
    }
    if ([long]$Artifact.id -ne $ArtifactId -or $Artifact.expired -isnot [bool] -or $Artifact.expired -or
        [long]$Artifact.workflow_run.id -ne $CiRunId -or
        [long]$Artifact.workflow_run.repository_id -ne $script:KafeRepositoryId -or
        [long]$Artifact.workflow_run.head_repository_id -ne $script:KafeRepositoryId -or
        $Artifact.workflow_run.head_branch -cne 'main' -or $Artifact.workflow_run.head_sha -ine $CommitSha -or
        $Artifact.name -cne ('kafe-web-' + $CommitSha.ToLowerInvariant()) -or
        [long]$Artifact.size_in_bytes -ne $ArchiveBytes -or
        [string]$Artifact.digest -notmatch '^sha256:[0-9a-fA-F]{64}$' -or
        $Artifact.digest -ine ('sha256:' + $ArchiveSha256)) {
        Stop-KafeOperation 'UnapprovedArtifact'
    }
}

function Confirm-KafeArtifact([string] $CommitSha, [long] $CiRunId, [long] $ArtifactId, [string] $ArchiveSha256, [long] $ArchiveBytes) {
    $run = Get-KafeApiObject ('actions/runs/' + $CiRunId)
    $artifact = Get-KafeApiObject ('actions/artifacts/' + $ArtifactId)
    $main = Get-KafeApiObject 'git/ref/heads/main'
    Assert-KafeArtifactMetadata $run $artifact $main $CommitSha $CiRunId $ArtifactId $ArchiveSha256 $ArchiveBytes
}

function Get-KafeUploadDirectory([string] $UploadId) {
    if ($UploadId -cnotmatch '^[0-9a-f]{32}$') { Stop-KafeOperation 'InvalidUploadId' }
    $incoming = Join-Path $script:KafeRoot 'remote-incoming'
    Assert-KafeNoReparse $incoming
    $directory = [IO.Path]::GetFullPath((Join-Path $incoming $UploadId))
    if (-not $directory.StartsWith($incoming + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-KafeOperation 'UploadPathRejected' }
    return $directory
}

function Open-KafeLock([string] $Path) {
    try { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { Stop-KafeOperation 'OperationBusy' }
}

function Save-KafeUploadState([string] $Directory, $State) {
    $statePath = Join-Path $Directory 'upload-state.json'
    $tempPath = Join-Path $Directory ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($tempPath, ($State | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    if ([IO.File]::Exists($statePath)) { [IO.File]::Replace($tempPath, $statePath, (Join-Path $Directory 'upload-state.previous.json')) }
    else { [IO.File]::Move($tempPath, $statePath) }
}

function Read-KafeUploadState([string] $Directory, [string] $Caller) {
    Assert-KafeNoReparse $Directory
    $path = Join-Path $Directory 'upload-state.json'
    Assert-KafeNoReparse $path
    $state = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($state.SchemaVersion -ne 1 -or $state.Caller -ine $Caller -or
        $state.UploadId -cne ([IO.Path]::GetFileName($Directory))) { Stop-KafeOperation 'UploadOwnerMismatch' }
    if ([DateTime]::Parse($state.ExpiresAtUtc).ToUniversalTime() -lt [DateTime]::UtcNow) { Stop-KafeOperation 'UploadExpired' }
    return $state
}

function Remove-KafeUploadDirectory([string] $Directory) {
    $incoming = Join-Path $script:KafeRoot 'remote-incoming'
    $resolved = [IO.Path]::GetFullPath($Directory)
    if (-not $resolved.StartsWith($incoming + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -cnotmatch '^[0-9a-f]{32}$') { Stop-KafeOperation 'UploadCleanupPathRejected' }
    Assert-KafeNoReparse $resolved
    foreach ($item in @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-KafeOperation 'ReparsePathRejected' }
    }
    # The exact absolute target was verified above as this module's own GUID upload directory.
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

function Expand-KafeArchiveSafely([IO.Stream] $Stream, [string] $Destination) {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    if ([IO.Directory]::Exists($Destination)) { Stop-KafeOperation 'ExtractionDestinationExists' }
    $archive = New-Object IO.Compression.ZipArchive($Stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        if ($archive.Entries.Count -eq 0 -or $archive.Entries.Count -gt $script:KafeMaxEntries) { Stop-KafeOperation 'ArchiveEntryLimit' }
        # Windows paths must be compared ordinally, regardless of the remoting user's culture.
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $plan = New-Object Collections.Generic.List[object]
        $total = [long]0
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or $name.Contains(':') -or
                $name.StartsWith('/') -or $name.Contains('//') -or $name -match '(^|/)\.{1,2}(/|$)') { Stop-KafeOperation 'ArchivePathRejected' }
            $isDirectory = $name.EndsWith('/')
            $normalized = $name.TrimEnd('/')
            foreach ($segment in $normalized.Split('/')) {
                if ([string]::IsNullOrWhiteSpace($segment) -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
                    $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
                    $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { Stop-KafeOperation 'ArchivePathRejected' }
            }
            if (-not $names.Add($normalized)) { Stop-KafeOperation 'ArchiveDuplicatePath' }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if (($entry.ExternalAttributes -band 0x400) -ne 0 -or $unixType -notin @(0, 0x8000, 0x4000)) { Stop-KafeOperation 'ArchiveLinkRejected' }
            if ($entry.Length -gt $script:KafeMaxEntryBytes -or $entry.Length -gt ($script:KafeMaxExpandedBytes - $total)) { Stop-KafeOperation 'ArchiveSizeLimit' }
            $total += $entry.Length
            $path = [IO.Path]::GetFullPath((Join-Path $Destination $normalized.Replace('/', '\')))
            if (-not $path.StartsWith($Destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-KafeOperation 'ArchivePathRejected' }
            $plan.Add([pscustomobject]@{ Entry = $entry; Path = $path; IsDirectory = $isDirectory })
        }
        $null = [IO.Directory]::CreateDirectory($Destination)
        $buffer = New-Object byte[] 65536
        $actualTotal = [long]0
        foreach ($item in $plan) {
            if ($item.IsDirectory) {
                if ($item.Entry.Length -ne 0) { Stop-KafeOperation 'ArchiveDirectoryDataRejected' }
                $null = [IO.Directory]::CreateDirectory($item.Path)
                continue
            }
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item.Path))
            $entryStream = $null; $output = $null
            try {
                $entryStream = $item.Entry.Open()
                $output = [IO.File]::Open($item.Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $entryBytes = [long]0
                while (($read = $entryStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $entryBytes += $read; $actualTotal += $read
                    if ($entryBytes -gt $script:KafeMaxEntryBytes -or $actualTotal -gt $script:KafeMaxExpandedBytes -or $entryBytes -gt $item.Entry.Length) { Stop-KafeOperation 'ArchiveSizeLimit' }
                    $output.Write($buffer, 0, $read)
                }
                if ($entryBytes -ne $item.Entry.Length) { Stop-KafeOperation 'ArchiveLengthMismatch' }
            }
            finally { if ($output) { $output.Dispose() }; if ($entryStream) { $entryStream.Dispose() } }
        }
    }
    finally { $archive.Dispose() }
}

function Get-KafeSmokeCredential($Configuration) {
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $path = Join-Path $script:KafeRoot 'secrets\smoke-password.bin'
    Assert-KafeNoReparse $path
    $plain = $null; $characters = $null
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), [Text.Encoding]::UTF8.GetBytes('KafeDemo-Smoke-v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $characters = [Text.Encoding]::UTF8.GetChars($plain)
        $password = New-Object Security.SecureString
        foreach ($character in $characters) { $password.AppendChar($character) }
        $password.MakeReadOnly()
        return (New-Object Management.Automation.PSCredential([string]$Configuration.SmokeUser, $password))
    }
    finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
        if ($null -ne $characters) { [Array]::Clear($characters, 0, $characters.Length) }
    }
}

function Invoke-KafeIisScript([hashtable] $Arguments) {
    # JEA hides external scripts from command lookup, including from this module.
    # Load only this fixed administrator-owned file into the trusted module scope.
    # Neither its path nor its source is supplied by the remote caller or artifact.
    $path = Join-Path $script:KafeRoot 'admin-tools\Deploy-Iis.ps1'
    Assert-KafeNoReparse $path
    $trustedScript = $ExecutionContext.SessionState.Module.NewBoundScriptBlock([scriptblock]::Create([IO.File]::ReadAllText($path)))
    & $trustedScript @Arguments
}

function Get-KafeDeploymentState {
    [CmdletBinding()]
    param()
    try {
        $null = Get-KafeCaller
        $null = Get-KafeConfiguration
        $current = $null; $previous = $null
        $path = Join-Path $script:KafeRoot 'deployment-state.json'
        if ([IO.File]::Exists($path)) {
            Assert-KafeNoReparse $path
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($state.schemaVersion -ne 1 -or $state.repository -cne $script:KafeRepository -or $state.siteName -cne 'KafeDemo') { Stop-KafeOperation 'DeploymentStateRejected' }
            if ($state.currentRelease) { $current = [string]$state.currentRelease.commitSha }
            if ($state.previousRelease) { $previous = [string]$state.previousRelease.commitSha }
            if (($current -and $current -notmatch '^[0-9a-fA-F]{40}$') -or ($previous -and $previous -notmatch '^[0-9a-fA-F]{40}$')) { Stop-KafeOperation 'DeploymentStateRejected' }
        }
        [pscustomobject]@{ ModuleVersion = '1.0.0'; CurrentCommitSha = $current; PreviousCommitSha = $previous }
    }
    catch { Write-KafeFailure 'GetState' $_ }
}

function Start-KafeUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommitSha,
        [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$CiRunId,
        [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$ArtifactId,
        [Parameter(Mandatory)][string]$ArchiveSha256,
        [Parameter(Mandatory)][ValidateRange(1,52428800)][long]$ArchiveBytes
    )
    $lock = $null
    try {
        if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$' -or $ArchiveSha256 -notmatch '^[0-9a-fA-F]{64}$') { Stop-KafeOperation 'InvalidRequest' }
        $caller = Get-KafeCaller
        $null = Get-KafeConfiguration
        $CommitSha = $CommitSha.ToLowerInvariant(); $ArchiveSha256 = $ArchiveSha256.ToLowerInvariant()
        Confirm-KafeArtifact $CommitSha $CiRunId $ArtifactId $ArchiveSha256 $ArchiveBytes
        $incoming = Join-Path $script:KafeRoot 'remote-incoming'
        Assert-KafeNoReparse $incoming
        $lock = Open-KafeLock (Join-Path $incoming '.uploads.lock')
        $active = 0
        foreach ($directory in @(Get-ChildItem -LiteralPath $incoming -Directory -Force)) {
            if ($directory.Name -cnotmatch '^[0-9a-f]{32}$') { Stop-KafeOperation 'UnexpectedIncomingDirectory' }
            Assert-KafeNoReparse $directory.FullName
            $statePath = Join-Path $directory.FullName 'upload-state.json'
            $expired = $directory.CreationTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-30)
            $finished = $false
            if ([IO.File]::Exists($statePath)) {
                Assert-KafeNoReparse $statePath
                $existing = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                $finished = $existing.Status -cin @('Completed', 'Failed')
            }
            if ($expired -or $finished) {
                $cleanupLock = $null
                try { $cleanupLock = Open-KafeLock (Join-Path $directory.FullName '.upload.lock') }
                catch { $active++; continue }
                $cleanupLock.Dispose()
                Remove-KafeUploadDirectory $directory.FullName
            }
            else { $active++ }
        }
        if ($active -ge 2) { Stop-KafeOperation 'UploadQuotaReached' }
        $id = [guid]::NewGuid().ToString('N')
        $directory = Get-KafeUploadDirectory $id
        $null = [IO.Directory]::CreateDirectory($directory)
        $stream = [IO.File]::Open((Join-Path $directory 'archive.zip'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        $state = @{
            SchemaVersion = 1; UploadId = $id; Caller = $caller; Status = 'Open'; NextIndex = 0; ReceivedBytes = [long]0
            CommitSha = $CommitSha; CiRunId = $CiRunId; ArtifactId = $ArtifactId; ArchiveSha256 = $ArchiveSha256; ArchiveBytes = $ArchiveBytes
            ExpiresAtUtc = [DateTime]::UtcNow.AddMinutes(30).ToString('o')
        }
        Save-KafeUploadState $directory $state
        Write-KafeAudit 'UploadStarted' '' $id $CiRunId $ArtifactId
        [pscustomobject]@{ UploadId = $id; ChunkBytes = $script:KafeChunkBytes; ArchiveBytes = $ArchiveBytes; CommitSha = $CommitSha }
    }
    catch { Write-KafeFailure 'StartUpload' $_ }
    finally { if ($lock) { $lock.Dispose() } }
}

function Send-KafeChunk {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UploadId,
        [Parameter(Mandatory)][ValidateRange(0,267)][int]$Index,
        [Parameter(Mandatory)][string]$Base64Data
    )
    $lock = $null; $stream = $null
    try {
        if ($UploadId -cnotmatch '^[0-9a-f]{32}$' -or $Base64Data.Length -lt 1 -or $Base64Data.Length -gt 262144 -or
            $Base64Data -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') { Stop-KafeOperation 'InvalidChunkRequest' }
        $caller = Get-KafeCaller
        $null = Get-KafeConfiguration
        $directory = Get-KafeUploadDirectory $UploadId
        Assert-KafeNoReparse $directory
        $lock = Open-KafeLock (Join-Path $directory '.upload.lock')
        $state = Read-KafeUploadState $directory $caller
        if ($state.Status -cne 'Open' -or [int]$state.NextIndex -ne $Index) { Stop-KafeOperation 'ChunkSequenceRejected' }
        try { $bytes = [Convert]::FromBase64String($Base64Data) } catch { Stop-KafeOperation 'ChunkEncodingRejected' }
        $expectedBytes = [Math]::Min([long]$script:KafeChunkBytes, ([long]$state.ArchiveBytes - [long]$state.ReceivedBytes))
        if ($expectedBytes -le 0 -or $bytes.Length -ne $expectedBytes) { Stop-KafeOperation 'ChunkLengthRejected' }
        $path = Join-Path $directory 'archive.zip'
        Assert-KafeNoReparse $path
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        if ($stream.Length -ne [long]$state.ReceivedBytes) { Stop-KafeOperation 'UploadLengthMismatch' }
        $null = $stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
        $stream.Dispose(); $stream = $null
        $state.ReceivedBytes = [long]$state.ReceivedBytes + $bytes.Length
        $state.NextIndex = [int]$state.NextIndex + 1
        Save-KafeUploadState $directory $state
        [pscustomobject]@{ UploadId = $UploadId; NextIndex = [int]$state.NextIndex; ReceivedBytes = [long]$state.ReceivedBytes }
    }
    catch { Write-KafeFailure 'SendChunk' $_ }
    finally { if ($stream) { $stream.Dispose() }; if ($lock) { $lock.Dispose() } }
}

function Publish-KafeUpload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UploadId)
    $lock = $null; $stream = $null
    try {
        if ($UploadId -cnotmatch '^[0-9a-f]{32}$') { Stop-KafeOperation 'InvalidUploadId' }
        $caller = Get-KafeCaller
        $configuration = Get-KafeConfiguration
        $directory = Get-KafeUploadDirectory $UploadId
        Assert-KafeNoReparse $directory
        $lock = Open-KafeLock (Join-Path $directory '.upload.lock')
        $state = Read-KafeUploadState $directory $caller
        if ($state.Status -cne 'Open' -or [long]$state.ReceivedBytes -ne [long]$state.ArchiveBytes) { Stop-KafeOperation 'UploadIncomplete' }
        $state.Status = 'Publishing'; Save-KafeUploadState $directory $state
        Confirm-KafeArtifact $state.CommitSha $state.CiRunId $state.ArtifactId $state.ArchiveSha256 $state.ArchiveBytes
        $zip = Join-Path $directory 'archive.zip'
        Assert-KafeNoReparse $zip
        $stream = [IO.File]::Open($zip, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        if ($stream.Length -ne [long]$state.ArchiveBytes -or $stream.Length -gt $script:KafeMaxArchiveBytes) { Stop-KafeOperation 'UploadLengthMismatch' }
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $hash = ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        if ($hash -cne $state.ArchiveSha256) { Stop-KafeOperation 'ArchiveDigestMismatch' }
        $stream.Position = 0
        $package = Join-Path $directory 'package'
        Expand-KafeArchiveSafely $stream $package
        $stream.Dispose(); $stream = $null
        $validation = Invoke-KafeIisScript @{ PackageDirectory = $package; ExpectedCommitSha = $state.CommitSha; ValidateOnly = $true; ErrorAction = 'Stop' }
        if (-not $validation.Valid -or -not $validation.Deployable) { Stop-KafeOperation 'PackageNotDeployable' }
        # Recheck current main and CI/artifact provenance after extraction, immediately before deployment.
        Confirm-KafeArtifact $state.CommitSha $state.CiRunId $state.ArtifactId $state.ArchiveSha256 $state.ArchiveBytes
        $credential = Get-KafeSmokeCredential $configuration
        $result = Invoke-KafeIisScript @{ PackageDirectory = $package; ExpectedCommitSha = $state.CommitSha; HealthCheckCredential = $credential; ErrorAction = 'Stop' }
        if ($result.CommitSha -ine $state.CommitSha -or $result.AuthenticatedHttp -ne 200 -or $result.AnonymousHttp -ne 401) { Stop-KafeOperation 'UnexpectedDeployResult' }
        $state.Status = 'Completed'; Save-KafeUploadState $directory $state
        Write-KafeAudit 'Published' '' $UploadId $state.CiRunId $state.ArtifactId
        [pscustomobject]@{ Operation = 'Deploy'; CommitSha = [string]$result.CommitSha; Site = 'KafeDemo'; AuthenticatedHttp = 200; AnonymousHttp = 401; DatabaseChanged = $false }
    }
    catch {
        $publishError = $_
        if ($lock -and (Get-Variable -Name state -ErrorAction SilentlyContinue) -and $state.Status -ceq 'Publishing') {
            try { $state.Status = 'Failed'; Save-KafeUploadState $directory $state } catch { }
        }
        Write-KafeFailure 'Publish' $publishError
    }
    finally { if ($stream) { $stream.Dispose() }; if ($lock) { $lock.Dispose() } }
}

function Invoke-KafeRollback {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExpectedCommitSha)
    try {
        if ($ExpectedCommitSha -notmatch '^[0-9a-fA-F]{40}$') { Stop-KafeOperation 'InvalidCommitSha' }
        $null = Get-KafeCaller
        $configuration = Get-KafeConfiguration
        $credential = Get-KafeSmokeCredential $configuration
        $result = Invoke-KafeIisScript @{ Rollback = $true; ExpectedCommitSha = $ExpectedCommitSha; HealthCheckCredential = $credential; ErrorAction = 'Stop' }
        if ($result.CommitSha -ine $ExpectedCommitSha -or $result.AuthenticatedHttp -ne 200 -or $result.AnonymousHttp -ne 401) { Stop-KafeOperation 'UnexpectedRollbackResult' }
        Write-KafeAudit 'RolledBack'
        [pscustomobject]@{ Operation = 'Rollback'; CommitSha = [string]$result.CommitSha; Site = 'KafeDemo'; AuthenticatedHttp = 200; AnonymousHttp = 401; DatabaseChanged = $false }
    }
    catch { Write-KafeFailure 'Rollback' $_ }
}

Export-ModuleMember -Function Get-KafeDeploymentState, Start-KafeUpload, Send-KafeChunk, Publish-KafeUpload, Invoke-KafeRollback
