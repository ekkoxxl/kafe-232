#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use elevated Windows PowerShell 5.1.' }
Import-Module WebAdministration
Add-Type -AssemblyName System.Security
$root = 'C:\KafeDemo'
$ip = '100.126.247.75'
$dnsName = 'win-m7lsg103n98.taildd9596.ts.net'
$endpoint = 'KafeDeploy'
$moduleRoot = Join-Path ${env:ProgramFiles} 'WindowsPowerShell\Modules\Kafe.Deployment\1.0.0'
$sourceModule = Join-Path $PSScriptRoot 'Kafe.Deployment'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stateRoot = Join-Path $root 'state'
$secretRoot = Join-Path $root 'secrets'
$adminRoot = Join-Path $root 'admin-tools'
$configPath = Join-Path $stateRoot 'remote-deploy.json'
$publisherName = 'kafepublisher'
$smokeName = 'kafesmoke'
$publisherUser = $env:COMPUTERNAME + '\' + $publisherName
$smokeUser = $env:COMPUTERNAME + '\' + $smokeName

function Set-AdminOnlyDirectory([string] $Path) {
    $null = New-Item -ItemType Directory -Path $Path -Force
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation paths cannot contain reparse points.' }
        $item = $item.Parent
    }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function New-ServicePassword {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes); return ('Kf!9' + [Convert]::ToBase64String($bytes)) }
    finally { $rng.Dispose(); [Array]::Clear($bytes, 0, $bytes.Length) }
}
function New-RestrictedLocalUser([string] $Name, [string] $Password, [string] $Description) {
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $null = New-LocalUser -Name $Name -Password $secure -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -Description $Description
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    Add-LocalGroupMember -Group $usersGroup -Member ($env:COMPUTERNAME + '\' + $Name)
}

if (-not (Test-Path -LiteralPath (Join-Path $sourceModule 'Kafe.Deployment.psd1'))) { throw 'The reviewed deployment module is missing.' }
foreach ($scriptName in @('Deploy-Iis.ps1','Rollback-Iis.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot ('scripts\' + $scriptName)))) { throw 'The reviewed IIS script is missing.' }
}
$site = Get-Website -Name KafeDemo
if (-not $site -or $site.applicationPool -ne 'KafeDemo') { throw 'Prepare the dedicated KafeDemo IIS site first.' }
$ts = (& 'C:\Program Files\Tailscale\tailscale.exe' status --json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or $ts.BackendState -ne 'Running' -or $ip -notin $ts.Self.TailscaleIPs) { throw 'Expected connected Tailscale address is missing.' }
if ($ts.Self.DNSName.TrimEnd('.') -ine $dnsName) { throw 'Tailscale DNS identity changed; review certificate settings first.' }
if (Test-Path -LiteralPath $configPath) { throw 'Remote deployment is already initialized. Do not rotate accounts or overwrite endpoint configuration implicitly.' }
foreach ($name in @($publisherName, $smokeName)) {
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { throw 'A planned service account already exists. Investigate before reusing it.' }
}
if (Get-PSSessionConfiguration -Name $endpoint -ErrorAction SilentlyContinue) { throw 'The planned JEA endpoint already exists.' }
if (Test-Path -LiteralPath $moduleRoot) { throw 'The planned module directory already exists.' }
if (Get-NetFirewallRule -Name 'KafeDemo-JEA-Tailscale-5986' -ErrorAction SilentlyContinue) { throw 'The planned firewall rule already exists.' }
foreach ($listener in @(Get-ChildItem WSMan:\localhost\Listener)) {
    $values = @{}
    Get-ChildItem $listener.PSPath | ForEach-Object { $values[$_.Name] = [string]$_.Value }
    if ($values['Transport'] -eq 'HTTPS') { throw 'An HTTPS WinRM listener already exists; do not alter it automatically.' }
}
if (-not $PSCmdlet.ShouldProcess('KafeDemo private deployment endpoint', 'Install restricted accounts, pinned module, HTTPS and JEA')) { return }

foreach ($path in @($stateRoot,$secretRoot,$adminRoot,(Join-Path $root 'remote-incoming'),(Join-Path $root 'jea-transcripts'))) { Set-AdminOnlyDirectory $path }
$backupName = 'Kafe-before-RemoteDeploy-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
Backup-WebConfiguration -Name $backupName | Out-Null
$publisherPassword = New-ServicePassword
$smokePassword = New-ServicePassword
try {
    New-RestrictedLocalUser $publisherName $publisherPassword 'Restricted KafeDemo JEA publisher'
    New-RestrictedLocalUser $smokeName $smokePassword 'KafeDemo HTTP smoke check'
    $publisherCredential = New-Object Management.Automation.PSCredential($publisherUser, (ConvertTo-SecureString $publisherPassword -AsPlainText -Force))
    $publisherCredential | Export-Clixml -LiteralPath (Join-Path $secretRoot 'publisher-credential.clixml')
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($smokePassword)
    try {
        $cipher = [Security.Cryptography.ProtectedData]::Protect($plainBytes, [Text.Encoding]::UTF8.GetBytes('KafeDemo-Smoke-v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        [IO.File]::WriteAllBytes((Join-Path $secretRoot 'smoke-password.bin'), $cipher)
    }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}
finally { $publisherPassword = $null; $smokePassword = $null; $publisherCredential = $null }

# Deny these machine-generated identities console and RDP sign-in. This only
# adds rights to the two new SIDs; it never replaces the machine's policy.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class KafeDenyInteractive {
 [StructLayout(LayoutKind.Sequential)] struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
 [StructLayout(LayoutKind.Sequential)] struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
 [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr name, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
 [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
 [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
 [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
 public static void Add(byte[] sid, string right) {
  var a=new LSA_OBJECT_ATTRIBUTES(); a.Length=Marshal.SizeOf(a); IntPtr h;
  uint s=LsaOpenPolicy(IntPtr.Zero,ref a,0x00000810,out h);
  if(s!=0) throw new Win32Exception((int)LsaNtStatusToWinError(s));
  IntPtr p=Marshal.StringToHGlobalUni(right);
  try { var r=new LSA_UNICODE_STRING {Length=(ushort)(right.Length*2),MaximumLength=(ushort)((right.Length+1)*2),Buffer=p}; s=LsaAddAccountRights(h,sid,new[]{r},1); if(s!=0)throw new Win32Exception((int)LsaNtStatusToWinError(s)); }
  finally { Marshal.FreeHGlobal(p); LsaClose(h); }
 }
}
'@
foreach ($name in @($publisherName,$smokeName)) {
    $sid = (Get-LocalUser -Name $name).SID
    $sidBytes = New-Object byte[] $sid.BinaryLength
    $sid.GetBinaryForm($sidBytes,0)
    foreach ($right in @('SeDenyInteractiveLogonRight','SeDenyRemoteInteractiveLogonRight')) { [KafeDenyInteractive]::Add($sidBytes,$right) }
}

$null = New-Item -ItemType Directory -Path $moduleRoot -Force
Set-AdminOnlyDirectory $moduleRoot
Copy-Item -LiteralPath (Join-Path $sourceModule 'Kafe.Deployment.psd1'),(Join-Path $sourceModule 'Kafe.Deployment.psm1') -Destination $moduleRoot
Copy-Item -LiteralPath (Join-Path $sourceModule 'RoleCapabilities') -Destination $moduleRoot -Recurse
# JEA locates role capability files as the connecting account before switching
# to its virtual identity. Grant that account read-only discovery, never write.
$moduleAcl = Get-Acl -LiteralPath $moduleRoot
$moduleAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($publisherUser, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $moduleRoot -AclObject $moduleAcl
foreach ($scriptName in @('Deploy-Iis.ps1','Rollback-Iis.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot ('scripts\' + $scriptName)) -Destination (Join-Path $adminRoot $scriptName) }

$config = [ordered]@{
    SchemaVersion=1; Repository='OrcunUcuncu/kafe-232'; RepositoryId=1431509368
    WorkflowPath='.github/workflows/ci.yml'; DeploymentRoot=$root; SmokeUser=$smokeUser
    PublisherUser=$publisherUser; EndpointName=$endpoint; Host=$ip; Port=5986
    IisBackup=$backupName; CreatedAtUtc=[DateTime]::UtcNow.ToString('o')
}
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

# Preserve the existing operator entry, but never introduce an all-users rule.
Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
$manager = New-Object Microsoft.Web.Administration.ServerManager
try {
    $collection = $manager.GetApplicationHostConfiguration().GetSection('system.webServer/security/authorization','KafeDemo').GetCollection()
    foreach ($rule in $collection) { if ($rule['users'] -eq '*' -and [int]$rule['accessType'] -eq 0) { throw 'Remove the inherited all-users authorization before continuing.' } }
    $smokeRule = $collection.CreateElement('add'); $smokeRule['accessType']='Allow'; $smokeRule['users']=$smokeUser
    $null = $collection.AddAt(0, $smokeRule)
    $manager.CommitChanges()
}
finally { $manager.Dispose() }

$sanExtension = '2.5.29.17={text}DNS=' + $dnsName + '&IPAddress=' + $ip
$certificate = New-SelfSignedCertificate -Type Custom -Subject ('CN=' + $dnsName) -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'KafeDemo private JEA HTTPS' -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyUsage DigitalSignature,KeyEncipherment -TextExtension @($sanExtension, '2.5.29.37={text}1.3.6.1.5.5.7.3.1') -NotAfter (Get-Date).AddYears(2)
$pem = "-----BEGIN CERTIFICATE-----`n" + [Convert]::ToBase64String($certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks) + "`n-----END CERTIFICATE-----`n"
$pem | Set-Content -LiteralPath (Join-Path $stateRoot 'winrm-ca.pem') -Encoding ASCII
$config['CertificateThumbprint'] = $certificate.Thumbprint
$config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8

& (Join-Path $PSScriptRoot 'Complete-KafeRemoteDeploy.ps1')
