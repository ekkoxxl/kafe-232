#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string] $ExpectedCommitSha,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,49}$')]
    [string] $SiteName = 'KafeDemo',

    [string] $DeploymentRoot = 'C:\KafeDemo',
    [uri] $HealthCheckUri = 'http://127.0.0.1:8080/',
    [System.Management.Automation.PSCredential] $HealthCheckCredential,
    [switch] $ValidateOnly
)

$ErrorActionPreference = 'Stop'
$arguments = @{
    Rollback = $true
    ExpectedCommitSha = $ExpectedCommitSha
    SiteName = $SiteName
    DeploymentRoot = $DeploymentRoot
    HealthCheckUri = $HealthCheckUri
    ValidateOnly = $ValidateOnly
}
if ($null -ne $HealthCheckCredential) { $arguments.HealthCheckCredential = $HealthCheckCredential }
if ($PSBoundParameters.ContainsKey('WhatIf')) { $arguments.WhatIf = $PSBoundParameters.WhatIf }
if ($PSBoundParameters.ContainsKey('Confirm')) { $arguments.Confirm = $PSBoundParameters.Confirm }
& (Join-Path $PSScriptRoot 'Deploy-Iis.ps1') @arguments
