#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
}

Describe 'Disconnect-AzFoundry' {
    BeforeEach {
        $env:AZURE_FOUNDRY_ENDPOINT = $null
        $env:AZURE_FOUNDRY_API_KEY = $null
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k')
        InModuleScope PwshAzureFoundry {
            $script:AzFoundryTokenCache['https://cognitiveservices.azure.com|u|t'] = [pscustomobject]@{
                Token = [securestring]::new(); ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
            }
        }
    }

    It 'clears the session and the token cache' {
        Disconnect-AzFoundry
        InModuleScope PwshAzureFoundry {
            $script:AzFoundryConnection | Should -BeNullOrEmpty
            $script:AzFoundryTokenCache.Count | Should -Be 0
        }
        Get-AzFoundryConnection | Should -BeNullOrEmpty
    }

    It 'outputs nothing and shows the endpoint in -Verbose' {
        $output = Disconnect-AzFoundry -Verbose 4>&1
        @($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count | Should -Be 0
        ($output.Message -join "`n") | Should -Match 'Disconnected from https://lab\.services\.ai\.azure\.com'
    }

    It 'does nothing and does not fail when not connected' {
        Disconnect-AzFoundry
        $output = Disconnect-AzFoundry -Verbose 4>&1
        ($output.Message -join "`n") | Should -Match 'Not connected'
    }

    It 'changes nothing with -WhatIf' {
        Disconnect-AzFoundry -WhatIf
        (Get-AzFoundryConnection).Endpoint | Should -Be 'https://lab.services.ai.azure.com'
    }

    It 'leaves the environment variables, and says they still apply' {
        $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.openai.azure.com'
        $env:AZURE_FOUNDRY_API_KEY = 'env-key'
        $output = Disconnect-AzFoundry -Verbose 4>&1
        ($output.Message -join "`n") | Should -Match 'AZURE_FOUNDRY_ENDPOINT is set'
        $env:AZURE_FOUNDRY_ENDPOINT | Should -Be 'https://env.openai.azure.com'
        (Get-AzFoundryConnection).Source | Should -Be 'Environment'
    }
}
