#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Get-AzFoundryAuthHeader' {
    It 'sends an API key as the api-key header' {
        InModuleScope PwshAzureFoundry {
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
            $connection.ApiKey = ConvertTo-AzFoundrySecureString -String 'key-123'
            $headers = Get-AzFoundryAuthHeader -Connection $connection
            $headers.Keys | Should -Be @('api-key')
            $headers['api-key'] | Should -Be 'key-123'
        }
    }

    It 'sends an Entra token as Authorization: Bearer, for the module scope resource' {
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryAccessToken {
            [pscustomobject]@{
                Token     = ConvertTo-SecureString -String 'entra-token' -AsPlainText -Force
                ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
            }
        }
        InModuleScope PwshAzureFoundry {
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'EntraId')
            $headers = Get-AzFoundryAuthHeader -Connection $connection
            $headers.Keys | Should -Be @('Authorization')
            $headers['Authorization'] | Should -Be 'Bearer entra-token'
        }
        Should -Invoke Get-AzFoundryAccessToken -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $ResourceUrl -eq 'https://cognitiveservices.azure.com'
        }
    }

    It 'fails when an ApiKey connection has no key' {
        {
            InModuleScope PwshAzureFoundry {
                $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
                Get-AzFoundryAuthHeader -Connection $connection
            }
        } | Should -Throw -ErrorId 'AzFoundryAuthMissing,Get-AzFoundryAuthHeader'
    }
}
