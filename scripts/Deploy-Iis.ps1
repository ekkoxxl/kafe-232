#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Deploy', ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Deploy')]
    [string] $PackageDirectory,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ExpectedCommitSha,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch] $Rollback,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,49}$')]
    [string] $SiteName = 'KafeDemo',

    [string] $DeploymentRoot = 'C:\KafeDemo',

    [uri] $HealthCheckUri = 'http://127.0.0.1:8080/',

    [System.Management.Automation.PSCredential] $HealthCheckCredential,

    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$expectedRepository = 'OrcunUcuncu/kafe-232'

function Get-FullDirectory([string] $Path) {
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {
        throw 'Use an absolute local directory, not a relative or UNC path.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) {
        throw 'A drive root cannot be a package or deployment directory.'
    }
    return $full
}

function Assert-NoReparsePoint([string] $Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Package and deployment paths cannot contain symbolic links or junctions.'
        }
        $item = $item.Parent
    }
}

function Assert-ChildPath([string] $Path, [string] $Parent) {
    if (-not $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release path is outside the configured releases directory.'
    }
}

function Get-ReleaseFileHash([string] $Path) {
    # Get-FileHash is a hidden nested-module function in a JEA runspace. Use the
    # fixed .NET hashing primitive instead of exposing extra remote commands.
    $stream = $null
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally { if ($stream) { $stream.Dispose() }; $hasher.Dispose() }
}

function Test-Package([string] $Directory, [string] $CommitSha) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        throw 'Package directory does not exist.'
    }
    Assert-NoReparsePoint $Directory
    $allItems = @(Get-ChildItem -LiteralPath $Directory -Force -Recurse)
    if (@($allItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -gt 0) {
        throw 'Package contains a symbolic link or junction.'
    }
    $manifestPath = Join-Path $Directory 'deployment-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'The CI deployment manifest is missing.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.repository -cne $expectedRepository -or
        $manifest.targetFramework -cne 'net481' -or $manifest.commitSha -ine $CommitSha) {
        throw 'Package repository, framework, schema or approved commit does not match.'
    }
    if ($manifest.PSObject.Properties.Name -notcontains 'sourceDirty' -or
        $manifest.PSObject.Properties.Name -notcontains 'validationOnly' -or
        $manifest.sourceDirty -isnot [bool] -or $manifest.validationOnly -isnot [bool]) {
        throw 'The manifest must include explicit boolean sourceDirty and validationOnly flags.'
    }
    if (-not $ValidateOnly -and ($manifest.sourceDirty -or $manifest.validationOnly)) {
        throw 'A dirty-source or validation-only package cannot be deployed.'
    }
    $inventory = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $relative = [string] $entry.path
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or
            $relative -match '(^/|:|//|(^|/)\.{1,2}(/|$))' -or
            $relative -ieq 'deployment-manifest.json') {
            throw 'Manifest contains an unsafe or reserved file path.'
        }
        foreach ($segment in $relative.Split('/')) {
            if ([string]::IsNullOrWhiteSpace($segment) -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or
                $segment.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
                throw 'Manifest contains an invalid Windows file name.'
            }
        }
        if ($inventory.Contains($relative) -or [string] $entry.sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Manifest contains duplicate paths or an invalid SHA256 checksum.'
        }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $Directory ($relative.Replace('/', '\'))))
        Assert-ChildPath $fullPath $Directory
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw 'A file listed in the manifest is missing.'
        }
        if ((Get-Item -LiteralPath $fullPath).Length -ne [long] $entry.length -or
            (Get-ReleaseFileHash $fullPath) -ine [string] $entry.sha256) {
            throw 'A package file differs from the CI checksum or length.'
        }
        $null = $inventory.Add($relative)
    }
    if ($inventory.Count -eq 0) { throw 'The package file inventory is empty.' }
    foreach ($file in @($allItems | Where-Object { -not $_.PSIsContainer })) {
        $relative = $file.FullName.Substring($Directory.Length + 1).Replace('\', '/')
        if ($relative -ieq 'deployment-manifest.json') { continue }
        if (-not $inventory.Contains($relative)) { throw 'Package contains a file absent from the CI inventory.' }
        if ($relative -match '(^|/)(\.git|\.github)(/|$)' -or
            $relative -match '\.(sql|mdf|ndf|ldf|bak|trn|pfx|p12|key|suo|user|csproj|sln|slnx)$' -or
            $file.Name -like '.env*') {
            throw 'Package contains source control, database, secret or development-only files.'
        }
    }
    foreach ($required in @('Web.config', 'Global.asax', 'bin\KafeYonetim.dll', 'Views\Web.config')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Directory $required) -PathType Leaf)) {
            throw 'The expected MVC web application output is incomplete.'
        }
    }
    [xml] $webConfig = Get-Content -LiteralPath (Join-Path $Directory 'Web.config') -Raw
    if ($webConfig.configuration.'system.web'.authentication.mode -cne 'Windows') {
        throw 'Package must preserve Windows Authentication.'
    }
    $compilation = $webConfig.configuration.'system.web'.compilation
    if ($compilation -and $compilation.GetAttribute('debug') -ieq 'true') {
        throw 'A debug build cannot be deployed.'
    }
    if (@($webConfig.SelectNodes('/configuration/system.web/authorization/deny[@users="?"]')).Count -eq 0) {
        throw 'Package must deny unauthenticated users.'
    }
    return $manifest
}

function Get-HttpStatus([bool] $UseWindowsCredentials) {
    $request = [Net.HttpWebRequest]::Create($HealthCheckUri)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 60000
    $request.UseDefaultCredentials = $UseWindowsCredentials
    if ($UseWindowsCredentials -and $null -ne $HealthCheckCredential) {
        $request.UseDefaultCredentials = $false
        $request.Credentials = $HealthCheckCredential.GetNetworkCredential()
    }
    $request.KeepAlive = $false
    $response = $null
    try { $response = $request.GetResponse(); return [int] $response.StatusCode }
    catch [Net.WebException] {
        if ($null -ne $_.Exception.Response) { $response = $_.Exception.Response; return [int] $response.StatusCode }
        throw
    }
    finally { if ($null -ne $response) { $response.Close() } }
}

function Test-RunningRelease {
    $status = 0
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $status = Get-HttpStatus $true
        if ($status -eq 200) { break }
        if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
    }
    if ($status -ne 200) { throw "Authenticated local smoke check returned HTTP $status, expected 200." }
    $anonymousStatus = Get-HttpStatus $false
    if ($anonymousStatus -ne 401) {
        throw "Anonymous local smoke check returned HTTP $anonymousStatus, expected 401."
    }
}

function Restart-DeploymentPool([string] $Name) {
    if ((Get-WebAppPoolState -Name $Name).Value -eq 'Started') { Restart-WebAppPool -Name $Name }
    else { Start-WebAppPool -Name $Name }
}

$root = Get-FullDirectory $DeploymentRoot
$releases = Join-Path $root 'releases'
$statePath = Join-Path $root 'deployment-state.json'
if (-not $HealthCheckUri.IsLoopback -or $HealthCheckUri.Scheme -notin @('http', 'https') -or
    $HealthCheckUri.UserInfo -or $HealthCheckUri.Query -or $HealthCheckUri.Fragment) {
    throw 'Smoke checks must use a credential-free loopback HTTP(S) URL without query or fragment.'
}
$state = $null
if (Test-Path -LiteralPath $root -PathType Container) { Assert-NoReparsePoint $root }
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -ne 1 -or $state.repository -cne $expectedRepository -or $state.siteName -cne $SiteName) {
        throw 'Deployment state belongs to another site, repository or schema.'
    }
}
if ($Rollback) {
    if ($null -eq $state -or $null -eq $state.previousRelease) { throw 'There is no previous deployed application release to roll back to.' }
    $source = Get-FullDirectory ([string] $state.previousRelease.path)
    Assert-ChildPath $source $releases
}
else {
    $source = Get-FullDirectory $PackageDirectory
    if ($source -ieq $releases -or $releases.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Package directory cannot contain the deployment destination.'
    }
}
$manifest = Test-Package $source $ExpectedCommitSha
if ($ValidateOnly) {
    [pscustomobject] @{ Valid = $true; Deployable = (-not $manifest.sourceDirty -and -not $manifest.validationOnly); SourceDirty = $manifest.sourceDirty; ValidationOnly = $manifest.validationOnly; Repository = $manifest.repository; CommitSha = $manifest.commitSha; Files = @($manifest.files).Count; Operation = $PSCmdlet.ParameterSetName }
    return
}
if (-not $PSCmdlet.ShouldProcess("$SiteName at $root", "$($PSCmdlet.ParameterSetName) approved commit $ExpectedCommitSha")) { return }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run an elevated Windows PowerShell session for IIS deployment.'
}
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Use Windows PowerShell 5.1 (powershell.exe) for the IIS WebAdministration module.' }
Import-Module WebAdministration -ErrorAction Stop
if (-not (Test-Path -LiteralPath $releases -PathType Container)) { throw 'Prepare the deployment root and IIS site before deploying.' }
Assert-NoReparsePoint $releases
$lock = $null
$oldPath = $null
$switched = $false
try {
    try { $lock = [IO.File]::Open((Join-Path $root '.deployment.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { throw 'Another deployment or rollback is already running.' }
    # Re-read state under the exclusive lock, preventing a concurrent deploy from using stale state.
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.schemaVersion -ne 1 -or $state.repository -cne $expectedRepository -or $state.siteName -cne $SiteName) { throw 'Deployment state validation failed.' }
    }
    $site = Get-Website -Name $SiteName
    if ($null -eq $site) { throw 'The configured IIS site does not exist.' }
    $matchingBinding = @($site.bindings.Collection | Where-Object {
        $binding = $_
        if ($binding.protocol -ne $HealthCheckUri.Scheme) { return $false }
        if ($binding.bindingInformation -notmatch '^(?<address>.*):(?<port>\d+):(?<host>[^:]*)$') { return $false }
        $address = $Matches.address.Trim('[', ']')
        $port = [int] $Matches.port
        $hostName = $Matches.host
        $requestHost = $HealthCheckUri.DnsSafeHost.Trim('[', ']')
        $loopbackAddresses = if ($requestHost -ieq 'localhost') { @('127.0.0.1', '::1') } else { @($requestHost) }
        return ($port -eq $HealthCheckUri.Port -and $address -in $loopbackAddresses -and
            ([string]::IsNullOrEmpty($hostName) -or $hostName -ieq $requestHost))
    })
    if ($matchingBinding.Count -eq 0) {
        throw 'The smoke URL must match an explicit loopback binding of the selected IIS site.'
    }
    $oldPath = Get-FullDirectory ([Environment]::ExpandEnvironmentVariables([string] $site.physicalPath))
    Assert-ChildPath $oldPath $releases
    Assert-NoReparsePoint $oldPath
    if ($state -and $state.currentRelease.path -ine $oldPath) { throw 'IIS path and saved deployment state differ; investigate before changing the site.' }
    $poolName = [string] $site.applicationPool
    $pool = Get-Item -LiteralPath ('IIS:\AppPools\' + $poolName)
    if ($pool.processModel.identityType.ToString() -ne 'ApplicationPoolIdentity' -or $pool.managedRuntimeVersion -ne 'v4.0') {
        throw 'The site must use a dedicated .NET v4 application pool with ApplicationPoolIdentity.'
    }
    if ($poolName -ne $SiteName) { throw 'Use a dedicated application pool named after this site.' }
    $windowsAuth = Get-WebConfigurationProperty -PSPath 'IIS:\' -Location $SiteName -Filter 'system.webServer/security/authentication/windowsAuthentication' -Name 'enabled'
    $anonymousAuth = Get-WebConfigurationProperty -PSPath 'IIS:\' -Location $SiteName -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name 'enabled'
    if (-not [bool] $windowsAuth.Value -or [bool] $anonymousAuth.Value) { throw 'IIS must have Windows Authentication enabled and Anonymous Authentication disabled.' }
    if ($Rollback) {
        if (-not $state.previousRelease -or $state.previousRelease.path -ine $source) { throw 'Previous release changed while waiting for the deployment lock.' }
        $target = $source
    }
    else {
        $releaseId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + $ExpectedCommitSha.Substring(0, 12) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $target = Join-Path $releases $releaseId
        Assert-ChildPath $target $releases
        $null = New-Item -ItemType Directory -Path $target
        foreach ($item in @(Get-ChildItem -LiteralPath $source -Force)) { Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force }
        $null = Test-Package $target $ExpectedCommitSha
        # Keep release code read-only to the application; deployment state is outside this tree.
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        $appRule = New-Object Security.AccessControl.FileSystemAccessRule(('IIS AppPool\' + $poolName), 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($appRule)
        Set-Acl -LiteralPath $target -AclObject $acl
    }
    if ($null -ne $HealthCheckCredential) {
        # IIS Windows Authentication also applies NTFS authorization for the
        # authenticated user. The dedicated non-admin smoke identity therefore
        # needs read access to this release, including rollback targets.
        $smokeIdentity = New-Object Security.Principal.NTAccount($HealthCheckCredential.UserName)
        $smokeSid = $smokeIdentity.Translate([Security.Principal.SecurityIdentifier])
        $targetDirectory = New-Object IO.DirectoryInfo($target)
        # Read/write only the DACL. A JEA virtual administrator must not try to
        # reassign an older release's original owner or primary group.
        $targetAcl = $targetDirectory.GetAccessControl([Security.AccessControl.AccessControlSections]::Access)
        $smokeRule = New-Object Security.AccessControl.FileSystemAccessRule($smokeSid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $targetAcl.SetAccessRule($smokeRule)
        $targetDirectory.SetAccessControl($targetAcl)
    }
    Set-ItemProperty -LiteralPath ('IIS:\Sites\' + $SiteName) -Name physicalPath -Value $target
    $switched = $true
    Restart-DeploymentPool $poolName
    if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') { Start-Website -Name $SiteName }
    Test-RunningRelease
    $previous = $null
    $oldManifestPath = Join-Path $oldPath 'deployment-manifest.json'
    if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
        $oldManifest = Get-Content -LiteralPath $oldManifestPath -Raw | ConvertFrom-Json
        $null = Test-Package $oldPath ([string] $oldManifest.commitSha)
        $previous = @{ path = $oldPath; commitSha = [string] $oldManifest.commitSha }
    }
    $newState = @{
        schemaVersion = 1; repository = $expectedRepository; siteName = $SiteName
        currentRelease = @{ path = $target; commitSha = $ExpectedCommitSha.ToLowerInvariant() }
        previousRelease = $previous; deployedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        operation = $PSCmdlet.ParameterSetName
    }
    $temporaryState = Join-Path $root ('deployment-state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporaryState, ($newState | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $statePath) {
        # Windows PowerShell 5.1 binds a null string argument as an empty path.
        # Keep an actual backup of the previous state for atomic replacement.
        $stateBackup = Join-Path $root ('deployment-state-' + [guid]::NewGuid().ToString('N') + '.previous.json')
        [IO.File]::Replace($temporaryState, $statePath, $stateBackup)
    }
    else { [IO.File]::Move($temporaryState, $statePath) }
    $switched = $false
    [pscustomobject] @{ Operation = $PSCmdlet.ParameterSetName; CommitSha = $ExpectedCommitSha.ToLowerInvariant(); Site = $SiteName; PhysicalPath = $target; AuthenticatedHttp = 200; AnonymousHttp = 401; DatabaseChanged = $false }
}
catch {
    $originalError = $_
    if ($switched -and $oldPath) {
        try {
            Set-ItemProperty -LiteralPath ('IIS:\Sites\' + $SiteName) -Name physicalPath -Value $oldPath
            Restart-DeploymentPool $poolName
            Write-Warning 'Deployment failed; the previous IIS physical path was restored. No database rollback was attempted.'
        }
        catch { throw 'Deployment failed and restoring the previous IIS physical path also failed. Check IIS and deployment-state.json before proceeding.' }
    }
    throw $originalError
}
finally { if ($null -ne $lock) { $lock.Dispose() } }
