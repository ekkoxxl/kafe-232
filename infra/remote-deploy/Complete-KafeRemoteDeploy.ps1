#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
$root = 'C:\KafeDemo'
$ip = '100.126.247.75'
$dnsName = 'win-m7lsg103n98.taildd9596.ts.net'
$endpoint = 'KafeDeploy'
$configPath = Join-Path $root 'state\remote-deploy.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$publisherUser = $env:COMPUTERNAME + '\kafepublisher'
if ($config.Repository -cne 'OrcunUcuncu/kafe-232' -or $config.PublisherUser -cne $publisherUser -or
    $config.DeploymentRoot -cne $root -or $config.EndpointName -cne $endpoint -or $config.Host -cne $ip -or $config.Port -ne 5986) {
    throw 'Pending setup configuration does not match this server.'
}
foreach ($name in @('kafepublisher','kafesmoke')) {
    if (-not (Get-LocalUser -Name $name -ErrorAction Stop).Enabled) { throw 'A prepared service account is disabled.' }
}
$certificate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $config.CertificateThumbprint)
if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date) -or $certificate.FriendlyName -cne 'KafeDemo private JEA HTTPS') { throw 'Expected server certificate is not available.' }
foreach ($path in @('admin-tools\Deploy-Iis.ps1','admin-tools\Rollback-Iis.ps1','secrets\publisher-credential.clixml','secrets\smoke-password.bin')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) { throw 'Pending setup is missing a protected file.' }
}
$moduleManifest = Join-Path ${env:ProgramFiles} 'WindowsPowerShell\Modules\Kafe.Deployment\1.0.0\Kafe.Deployment.psd1'
$roleFile = Join-Path (Split-Path -Parent $moduleManifest) 'RoleCapabilities\KafePublisher.psrc'
Import-Module $moduleManifest -Force
$roles = @{}; $roles[$publisherUser] = @{RoleCapabilityFiles=$roleFile}
$psscPath = Join-Path $root 'admin-tools\KafeDeploy.pssc'
New-PSSessionConfigurationFile -Path $psscPath -SessionType RestrictedRemoteServer -RunAsVirtualAccount -RoleDefinitions $roles -ModulesToImport @('C:\Program Files\WindowsPowerShell\Modules\Kafe.Deployment\1.0.0\Kafe.Deployment.psd1') -TranscriptDirectory (Join-Path $root 'jea-transcripts')
if (-not (Test-PSSessionConfigurationFile -Path $psscPath)) { throw 'JEA configuration validation failed.' }
Register-PSSessionConfiguration -Name $endpoint -Path $psscPath -Force -NoServiceRestart -MaximumReceivedDataSizePerCommandMB 2 -MaximumReceivedObjectSizeMB 1
$hasListener = $false
foreach ($listener in @(Get-ChildItem WSMan:\localhost\Listener)) {
    $values = @{}
    Get-ChildItem $listener.PSPath | ForEach-Object { $values[$_.Name] = [string]$_.Value }
    if ($values['Transport'] -ne 'HTTPS') { continue }
    if ($values['CertificateThumbprint'] -ine $certificate.Thumbprint -or $values['Port'] -ne '5986' -or $values['Address'] -cne ('IP:' + $ip)) { throw 'Another HTTPS listener exists; investigate before modifying it.' }
    $hasListener = $true
}
if (-not $hasListener) {
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address ('IP:' + $ip) -HostName $dnsName -CertificateThumbPrint $certificate.Thumbprint -Port 5986 -Force | Out-Null
}
$firewall = Get-NetFirewallRule -Name 'KafeDemo-JEA-Tailscale-5986' -ErrorAction SilentlyContinue
if (-not $firewall) {
    New-NetFirewallRule -Name 'KafeDemo-JEA-Tailscale-5986' -DisplayName 'KafeDemo restricted deployment via Tailscale HTTPS' -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP -LocalAddress $ip -LocalPort 5986 -RemoteAddress '100.64.0.0/10' -InterfaceAlias 'Tailscale' | Out-Null
}
Restart-Service WinRM
try {
    $capabilities = @(Get-PSSessionCapability -ConfigurationName $endpoint -Username $publisherUser -ErrorAction Stop | Select-Object -ExpandProperty Name)
}
catch {
    # This inspection helper cannot resolve some standalone local accounts.
    # Real authenticated positive/negative endpoint probes are still required.
    Write-Warning 'Capability inspection could not resolve the local account; actual endpoint probes remain required.'
    $capabilities = @((Import-PowerShellDataFile -LiteralPath $roleFile).VisibleFunctions)
}
foreach ($function in @('Get-KafeDeploymentState','Start-KafeUpload','Send-KafeChunk','Publish-KafeUpload','Invoke-KafeRollback')) {
    if ($function -notin $capabilities) { throw 'A required restricted deployment command is missing.' }
}
foreach ($forbidden in @('Invoke-Expression','Invoke-Command','Start-Process','Get-Content','Set-Content','Copy-Item','Import-Module')) {
    if ($forbidden -in $capabilities) { throw 'The endpoint exposes a generic administrative command.' }
}
$config | Add-Member -NotePropertyName EndpointSetupCompleted -NotePropertyValue $true -Force
$config | Add-Member -NotePropertyName RemoteEndpointVerified -NotePropertyValue $false -Force
$config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8
[pscustomobject]@{Endpoint=$endpoint;Host=$ip;Port=5986;PublisherUser=$publisherUser;SmokeUser=$config.SmokeUser;CertificateThumbprint=$certificate.Thumbprint;PublicCertificatePath=(Join-Path $root 'state\winrm-ca.pem');DatabaseChanged=$false;RemoteCloudVerified=$false}
