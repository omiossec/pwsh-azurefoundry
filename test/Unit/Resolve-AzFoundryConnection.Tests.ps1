#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY

    function Set-TestSession {
        param([string]$Endpoint, [string]$AuthMode = 'ApiKey', [string]$Key = 'session-key-value')
        InModuleScope PwshAzureFoundry -Parameters @{ Endpoint = $Endpoint; AuthMode = $AuthMode; Key = $Key } {
            param($Endpoint, $AuthMode, $Key)
            if (-not $Endpoint) {
                $script:AzFoundryConnection = $null
                return
            }
            $connection = [AzFoundryConnection]::new($Endpoint, $AuthMode)
            if ($AuthMode -eq 'ApiKey') {
                $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $Key
            }
            $connection.ResourceGroupName = 'rg-test'
            $script:AzFoundryConnection = $connection
        }
    }

    function Resolve-Test {
        param([hashtable]$Parameters = @{})
        InModuleScope PwshAzureFoundry -Parameters @{ P = $Parameters } {
            param($P)
            Resolve-AzFoundryConnection @P
        }
    }

    function Get-TestKey {
        param($Connection)
        [System.Net.NetworkCredential]::new('', $Connection.ApiKey).Password
    }
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
}

Describe 'Resolve-AzFoundryConnection' {
    BeforeEach {
        Set-TestSession -Endpoint $null
        $env:AZURE_FOUNDRY_ENDPOINT = $null
        $env:AZURE_FOUNDRY_API_KEY = $null
    }

    Context 'explicit parameters' {
        It 'uses -Endpoint with -ApiKey' {
            $result = Resolve-Test @{
                Endpoint = 'https://lab.openai.azure.com/openai/v1'
                ApiKey   = New-TestSecureString 'param-key'
            }
            $result.Endpoint | Should -Be 'https://lab.openai.azure.com'
            $result.AuthMode | Should -Be 'ApiKey'
            $result.Source | Should -Be 'Parameter'
            $result.AccountName | Should -Be 'lab'
            Get-TestKey $result | Should -Be 'param-key'
        }

        It 'uses -Endpoint with -UseEntraId' {
            $result = Resolve-Test @{ Endpoint = 'https://lab.services.ai.azure.com'; UseEntraId = $true }
            $result.AuthMode | Should -Be 'EntraId'
            $result.ApiKey | Should -BeNullOrEmpty
        }

        It 'rejects -ApiKey together with -UseEntraId' {
            { Resolve-Test @{ ApiKey = New-TestSecureString 'k'; UseEntraId = $true } } |
                Should -Throw -ErrorId 'AzFoundryAuthConflict,Resolve-AzFoundryConnection'
        }

        It 'reuses the session credentials when -Endpoint is the same resource in the other host form' {
            Set-TestSession -Endpoint 'https://lab.services.ai.azure.com'
            $result = Resolve-Test @{ Endpoint = 'https://lab.openai.azure.com' }
            $result.Endpoint | Should -Be 'https://lab.openai.azure.com'
            $result.Source | Should -Be 'Parameter'
            $result.ResourceGroupName | Should -Be 'rg-test'
            Get-TestKey $result | Should -Be 'session-key-value'
        }

        It 'never sends the session key to another resource' {
            Set-TestSession -Endpoint 'https://lab.services.ai.azure.com'
            $err = { Resolve-Test @{ Endpoint = 'https://other.services.ai.azure.com' } } |
                Should -Throw -ErrorId 'AzFoundryAuthMissing,Resolve-AzFoundryConnection' -PassThru
            $err.ErrorDetails.RecommendedAction | Should -Match '-ApiKey or -UseEntraId'
        }

        It 'refuses an -Endpoint outside Azure without -AllowCustomEndpoint' {
            { Resolve-Test @{ Endpoint = 'https://ai.contoso.com'; UseEntraId = $true } } |
                Should -Throw -ErrorId 'AzFoundryEndpointNotAzure*'
        }

        It 'accepts an -Endpoint outside Azure with -AllowCustomEndpoint, warning once per host' {
            InModuleScope PwshAzureFoundry { $script:AzFoundryCustomHostWarned.Clear() }
            $parameters = @{ Endpoint = 'https://ai.contoso.com'; UseEntraId = $true; AllowCustomEndpoint = $true }
            $first = @(Resolve-Test $parameters 3>&1)
            $second = @(Resolve-Test $parameters 3>&1)
            @($first | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 1
            @($second | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
            ($first | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }).Endpoint |
                Should -Be 'https://ai.contoso.com'
        }

        It 'reuses a custom session endpoint without -AllowCustomEndpoint (checked by Connect-AzFoundry)' {
            Set-TestSession -Endpoint 'https://ai.contoso.com'
            (Resolve-Test @{ Endpoint = 'https://ai.contoso.com' }).Endpoint | Should -Be 'https://ai.contoso.com'
        }

        It 'fails on -Endpoint without credentials and without a session' {
            { Resolve-Test @{ Endpoint = 'https://lab.services.ai.azure.com' } } |
                Should -Throw -ErrorId 'AzFoundryAuthMissing,Resolve-AzFoundryConnection'
        }

        It 'rejects a non-https -Endpoint' {
            { Resolve-Test @{ Endpoint = 'http://lab.services.ai.azure.com'; UseEntraId = $true } } |
                Should -Throw -ErrorId 'AzFoundryEndpointNotHttps,ConvertTo-AzFoundryEndpoint'
        }
    }

    Context 'session' {
        It 'returns the session connection' {
            Set-TestSession -Endpoint 'https://lab.services.ai.azure.com'
            $result = Resolve-Test
            $result.Endpoint | Should -Be 'https://lab.services.ai.azure.com'
            $result.Source | Should -Be 'Session'
        }

        It 'overrides the session auth with -UseEntraId without changing the session' {
            Set-TestSession -Endpoint 'https://lab.services.ai.azure.com'
            $result = Resolve-Test @{ UseEntraId = $true }
            $result.AuthMode | Should -Be 'EntraId'
            $result.Source | Should -Be 'Parameter'
            InModuleScope PwshAzureFoundry { $script:AzFoundryConnection.AuthMode } | Should -Be 'ApiKey'
        }

        It 'prefers the session over the environment variables' {
            Set-TestSession -Endpoint 'https://lab.services.ai.azure.com'
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.services.ai.azure.com'
            $env:AZURE_FOUNDRY_API_KEY = 'env-key'
            (Resolve-Test).Endpoint | Should -Be 'https://lab.services.ai.azure.com'
        }
    }

    Context 'environment variables' {
        It 'falls back to AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.services.ai.azure.com/'
            $env:AZURE_FOUNDRY_API_KEY = 'env-key-value'
            $result = Resolve-Test
            $result.Endpoint | Should -Be 'https://env.services.ai.azure.com'
            $result.Source | Should -Be 'Environment'
            $result.ApiKey | Should -BeOfType [securestring]
            Get-TestKey $result | Should -Be 'env-key-value'
        }

        It 'says so in -Verbose without showing the key' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.services.ai.azure.com'
            $env:AZURE_FOUNDRY_API_KEY = 'env-key-value'
            $verbose = InModuleScope PwshAzureFoundry { Resolve-AzFoundryConnection -Verbose 4>&1 } |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
            ($verbose.Message -join "`n") | Should -Match 'AZURE_FOUNDRY_ENDPOINT'
            ($verbose.Message -join "`n") | Should -Not -Match 'env-key-value'
        }

        It 'uses -UseEntraId with the environment endpoint and no key variable' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.services.ai.azure.com'
            $result = Resolve-Test @{ UseEntraId = $true }
            $result.AuthMode | Should -Be 'EntraId'
            $result.Source | Should -Be 'Environment'
        }

        It 'refuses an AZURE_FOUNDRY_ENDPOINT outside Azure, pointing to Connect-AzFoundry -AllowCustomEndpoint' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://ai.contoso.com'
            $env:AZURE_FOUNDRY_API_KEY = 'env-key-value'
            $err = { Resolve-Test } | Should -Throw -ErrorId 'AzFoundryEndpointNotAzure*' -PassThru
            $err.ErrorDetails.RecommendedAction | Should -Match 'Connect-AzFoundry .*-AllowCustomEndpoint'
            $err.ToString() | Should -Not -Match 'env-key-value'
        }

        It 'fails when only the endpoint variable is set' {
            $env:AZURE_FOUNDRY_ENDPOINT = 'https://env.services.ai.azure.com'
            $err = { Resolve-Test } | Should -Throw -ErrorId 'AzFoundryAuthMissing,Resolve-AzFoundryConnection' -PassThru
            $err.Exception.Message | Should -Match 'AZURE_FOUNDRY_API_KEY'
        }
    }

    It 'fails with a hint when nothing is configured' {
        $err = { Resolve-Test } | Should -Throw -ErrorId 'AzFoundryNotConnected,Resolve-AzFoundryConnection' -PassThru
        $err.CategoryInfo.Category | Should -Be 'InvalidOperation'
        $err.ErrorDetails.RecommendedAction | Should -Match 'Connect-AzFoundry'
        $err.ErrorDetails.RecommendedAction | Should -Match 'AZURE_FOUNDRY_ENDPOINT'
    }
}
