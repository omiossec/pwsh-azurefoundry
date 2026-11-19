#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'AzFoundryConnection' {
    It 'derives the account name from <Endpoint>' -ForEach @(
        @{ Endpoint = 'https://lab.services.ai.azure.com'; Expected = 'lab' }
        @{ Endpoint = 'https://Lab-1.openai.azure.com/openai/v1'; Expected = 'lab-1' }
        @{ Endpoint = 'https://lab.cognitiveservices.azure.com/'; Expected = 'lab' }
        @{ Endpoint = 'https://ai.contoso.com'; Expected = '' }
        @{ Endpoint = 'not a uri'; Expected = '' }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Endpoint = $Endpoint } {
            param($Endpoint)
            [AzFoundryConnection]::GetAccountName($Endpoint)
        } | Should -BeExactly $Expected
    }

    It 'treats both host forms of a resource as the same resource' {
        InModuleScope PwshAzureFoundry {
            [AzFoundryConnection]::IsSameResource('https://lab.services.ai.azure.com', 'https://lab.openai.azure.com') |
                Should -BeTrue
            [AzFoundryConnection]::IsSameResource('https://lab.services.ai.azure.com', 'https://other.openai.azure.com') |
                Should -BeFalse
            [AzFoundryConnection]::IsSameResource('https://ai.contoso.com', 'https://ai.contoso.com/') | Should -BeTrue
            [AzFoundryConnection]::IsSameResource('https://ai.contoso.com', 'https://ai.fabrikam.com') | Should -BeFalse
            [AzFoundryConnection]::IsSameResource($null, 'https://ai.fabrikam.com') | Should -BeFalse
        }
    }

    It 'never shows the key in ToString or the default output' {
        InModuleScope PwshAzureFoundry {
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
            $connection.ApiKey = ConvertTo-AzFoundrySecureString -String 'super-secret-key-value'

            $connection.ToString() | Should -Be 'https://lab.services.ai.azure.com (ApiKey)'
            ($connection | Format-List * | Out-String) | Should -Not -Match 'super-secret|ApiKey\s*:'
            $connection.AccountName | Should -Be 'lab'
        }
    }

    It 'clones into an independent object' {
        InModuleScope PwshAzureFoundry {
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
            $copy = $connection.Clone()
            $copy.AuthMode = 'EntraId'
            $connection.AuthMode | Should -Be 'ApiKey'
        }
    }
}
