#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:testKey = 'env-SECRET-key-0123456789'
    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
    InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
}

Describe 'Get-AzFoundryConnection' {
    BeforeEach {
        $env:AZURE_FOUNDRY_ENDPOINT = $null
        $env:AZURE_FOUNDRY_API_KEY = $null
        InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
    }

    It 'outputs nothing and says why in -Verbose when not connected' {
        $output = Get-AzFoundryConnection -Verbose 4>&1
        @($output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }).Count | Should -Be 0
        $output.Message | Should -Match 'Not connected.*AZURE_FOUNDRY_ENDPOINT'
    }

    It 'shows the session connection without the key' {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString $script:testKey)
        $result = Get-AzFoundryConnection

        $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.Connection'
        $result.Endpoint | Should -Be 'https://lab.services.ai.azure.com'
        $result.AccountName | Should -Be 'lab'
        $result.AuthMode | Should -Be 'ApiKey'
        $result.Source | Should -Be 'Session'
        $result.PSObject.Properties.Name | Should -Not -Contain 'ApiKey'
        ($result | Format-List * | Out-String) | Should -Not -Match ([regex]::Escape($script:testKey))
    }

    It 'returns a copy: changing it does not change the session' {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k')
        (Get-AzFoundryConnection).Endpoint = 'https://evil.example.com'
        (Get-AzFoundryConnection).Endpoint | Should -Be 'https://lab.services.ai.azure.com'
    }

    It 'has a default table view with AccountName, Endpoint, AuthMode and Source' {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k')
        $table = Get-AzFoundryConnection | Out-String
        $table | Should -Match 'AccountName\s+Endpoint\s+AuthMode\s+Source'
        $table | Should -Match 'lab\s+https://lab\.services\.ai\.azure\.com\s+ApiKey\s+Session'
    }

    Context 'environment variable fallback' {
        It 'uses the environment variables when there is no session (Source = Environment)' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.openai.azure.com/openai/v1'
            $env:AZURE_FOUNDRY_API_KEY = $script:testKey

            $output = Get-AzFoundryConnection -Verbose 4>&1
            $result = $output | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] }
            $verbose = ($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }).Message -join "`n"

            $result.Endpoint | Should -Be 'https://env.openai.azure.com'
            $result.AuthMode | Should -Be 'ApiKey'
            $result.Source | Should -Be 'Environment'
            $verbose | Should -Match 'AZURE_FOUNDRY_ENDPOINT'
            (($result | Format-List * | Out-String) + $verbose) | Should -Not -Match ([regex]::Escape($script:testKey))
        }

        It 'prefers the session over the environment variables' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.openai.azure.com'
            $env:AZURE_FOUNDRY_API_KEY = $script:testKey
            Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k')
            $result = Get-AzFoundryConnection
            $result.Endpoint | Should -Be 'https://lab.services.ai.azure.com'
            $result.Source | Should -Be 'Session'
        }

        It 'fails when the endpoint variable is set without the key' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.openai.azure.com'
            $err = { Get-AzFoundryConnection } |
                Should -Throw -ErrorId 'AzFoundryAuthMissing,Get-AzFoundryConnection' -PassThru
            $err.Exception.Message | Should -Match 'AZURE_FOUNDRY_API_KEY'
        }

        It 'fails on a non-https endpoint variable' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'http://env.openai.azure.com'
            $env:AZURE_FOUNDRY_API_KEY = $script:testKey
            { Get-AzFoundryConnection } | Should -Throw -ErrorId 'AzFoundryEndpointNotHttps,Get-AzFoundryConnection'
        }
    }
}
