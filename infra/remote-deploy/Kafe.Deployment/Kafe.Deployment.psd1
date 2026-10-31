@{
    RootModule = 'Kafe.Deployment.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'ea0c9769-57ae-416b-b34a-18ea1e827dc6'
    Author = 'Kafe deployment maintainers'
    Description = 'Restricted artifact upload and approved IIS deployment operations for the KafeDemo JEA endpoint.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop')
    FunctionsToExport = @('Get-KafeDeploymentState', 'Start-KafeUpload', 'Send-KafeChunk', 'Publish-KafeUpload', 'Invoke-KafeRollback')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
