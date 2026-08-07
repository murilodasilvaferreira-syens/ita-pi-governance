@{
    RootModule        = 'PIInventory.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '2f8c1d34-9b6e-4a71-8f0c-5d2e7a41b933'
    Author            = 'ITA Digital Ops'
    CompanyName       = 'Syensqo'
    Copyright         = 'Uso interno'
    Description       = 'Extração READ-ONLY de metadados do PI System (Data Archive + AF) para monitoramento contínuo no Microsoft Fabric. Este módulo nunca escreve no PI System.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Import-PISdk',
        'Get-InventoryEnvironment',
        'Initialize-PIConnection',
        'Write-InventoryLog',
        'Write-InventoryOutput',
        'ConvertFrom-AFConfigString',
        'Get-InventoryDatasetMap',
        'Write-InventoryManifest',
        'Copy-InventorySnapshot',
        'Remove-ExpiredSnapshot',
        'Invoke-InventorySnapshot',
        'Export-PIPointInventory',
        'Export-PIPointHealth',
        'Export-PIDigitalSetInventory',
        'Export-AFElementInventory',
        'Export-AFAttributeInventory',
        'Export-AFTemplateInventory',
        'Export-AFEventFrameInventory',
        'Export-AFAnalysisInventory',
        'Export-AFAnalysisOutputInventory',
        'Export-AFEnumerationSetInventory',
        'Export-AFUomInventory',
        'Export-AFTableInventory'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags       = @('PI', 'OSIsoft', 'AVEVA', 'AF', 'Inventory', 'ReadOnly')
            ProjectUri = ''
        }
    }
}
