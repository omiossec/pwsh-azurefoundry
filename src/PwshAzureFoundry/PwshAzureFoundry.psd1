@{
    RootModule           = 'PwshAzureFoundry.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Core')
    GUID                 = 'e0616f7a-879f-41e9-9098-ff5aaf8c572a'
    Author               = 'Olivier Miossec'
    CompanyName          = 'Olivier Miossec'
    Copyright            = '(c) Olivier Miossec. All rights reserved.'
    Description          = 'Call, list, deploy and locate models on an Azure AI Foundry resource from PowerShell.'
    PowerShellVersion    = '7.4'

    FormatsToProcess     = @('PwshAzureFoundry.Format.ps1xml')

    # Explicit list, no wildcards. Module.Tests.ps1 checks it matches Public/*.ps1.
    FunctionsToExport    = @(
        'Connect-AzFoundry', 'Disconnect-AzFoundry', 'Get-AzFoundryConnection',
        'Invoke-AzFoundryChat', 'New-AzFoundryMessage', 'New-AzFoundryTool',
        'Invoke-AzFoundryEmbedding', 'Invoke-AzFoundryDecision',
        'Get-AzFoundryModel', 'Get-AzFoundryDeployment', 'New-AzFoundryDeployment', 'Remove-AzFoundryDeployment',
        'Get-AzFoundryEndpoint'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @(
                'Azure', 'AzureAI', 'AIFoundry', 'Foundry', 'OpenAI', 'LLM', 'AI',
                'PSEdition_Core', 'Windows', 'Linux', 'MacOS'
            )
            LicenseUri   = 'https://github.com/omiossec/pwsh-azurefoundry/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/omiossec/pwsh-azurefoundry'
            ReleaseNotes = 'https://github.com/omiossec/pwsh-azurefoundry/blob/main/CHANGELOG.md'
            Prerelease   = 'alpha'
        }
    }
}
