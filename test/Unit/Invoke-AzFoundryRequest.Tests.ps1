#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:testKey = 'k3y-SECRET-0123456789abcdef'

    # Calls Invoke-AzFoundryRequest with an ApiKey connection (or EntraId with -Entra).
    function Invoke-Test {
        param([hashtable]$Parameters = @{}, [switch]$Entra)
        InModuleScope PwshAzureFoundry -Parameters @{ P = $Parameters; K = $script:testKey; E = [bool]$Entra } {
            param($P, $K, $E)
            $mode = if ($E) { 'EntraId' } else { 'ApiKey' }
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', $mode)
            if (-not $E) {
                $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $K
            }
            $call = @{ Connection = $connection; Path = '/openai/v1/chat/completions' }
            foreach ($key in $P.Keys) { $call[$key] = $P[$key] }
            Invoke-AzFoundryRequest @call
        }
    }
}

Describe 'Invoke-AzFoundryRequest' {
    Context 'request building' {
        BeforeEach {
            Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest {
                Get-TestFixtureResponse 'chat-completion'
            }
        }

        It 'POSTs compressed JSON to the endpoint + path with the api-key header' {
            $body = [ordered]@{
                model    = 'Mistral-Large-3'
                messages = @([ordered]@{ role = 'user'; content = 'hi' })
                nested   = @{ a = @{ b = @{ c = @{ d = @{ e = 'deep' } } } } }
            }
            $expected = '{"model":"Mistral-Large-3","messages":[{"role":"user","content":"hi"}],' +
                '"nested":{"a":{"b":{"c":{"d":{"e":"deep"}}}}}}'
            Invoke-Test @{ Body = $body } | Out-Null
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://lab.services.ai.azure.com/openai/v1/chat/completions' -and
                $Method -eq 'POST' -and
                $Headers['api-key'] -eq $script:testKey -and
                $Body -eq $expected -and
                $TimeoutSec -eq 120
            }
        }

        It 'sends a string body as is and passes -TimeoutSec' {
            Invoke-Test @{ Body = '{"raw":true}'; TimeoutSec = 15 } | Out-Null
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -ParameterFilter {
                $Body -eq '{"raw":true}' -and $TimeoutSec -eq 15
            }
        }

        It 'adds the query string and skips null values' {
            Invoke-Test @{ Method = 'GET'; Query = @{ 'api-version' = '2024-05-01-preview'; skip = $null } } | Out-Null
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -ParameterFilter {
                $Uri -eq 'https://lab.services.ai.azure.com/openai/v1/chat/completions?api-version=2024-05-01-preview' -and
                $Method -eq 'GET' -and -not $Body
            }
        }

        It 'uses a Bearer token for an EntraId connection' {
            Mock -ModuleName PwshAzureFoundry Get-AzFoundryAccessToken {
                [pscustomobject]@{
                    Token     = ConvertTo-SecureString 'entra-token' -AsPlainText -Force
                    ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
                }
            }
            Invoke-Test -Entra | Out-Null
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -ParameterFilter {
                $Headers['Authorization'] -eq 'Bearer entra-token' -and -not $Headers.ContainsKey('api-key')
            }
        }
    }

    Context 'responses' {
        It 'returns the parsed JSON' {
            Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest { Get-TestFixtureResponse 'chat-completion' }
            $result = Invoke-Test
            $result.choices[0].message.role | Should -Be 'assistant'
            $result.usage.total_tokens | Should -BeGreaterThan 0
        }

        It 'returns status and headers with -IncludeResponseInfo' {
            Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest { Get-TestFixtureResponse 'chat-completion' }
            $result = Invoke-Test @{ IncludeResponseInfo = $true }
            $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.HttpResponse'
            $result.StatusCode | Should -Be 200
            $result.Headers['x-ratelimit-remaining-requests'] | Should -Be '19'
            $result.Content.object | Should -Be 'chat.completion'
        }

        It 'outputs nothing for an empty body' {
            Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest { New-TestResponse -StatusCode 204 }
            @(Invoke-Test).Count | Should -Be 0
        }

        It 'throws the mapped error for <Fixture>' -ForEach @(
            @{ Fixture = 'error-deployment-not-found.json'; Status = 404; ErrorId = 'AzFoundry.DeploymentNotFound' }
            @{ Fixture = 'error-401.json'; Status = 401; ErrorId = 'AzFoundry.Http401' }
            @{ Fixture = 'error-deployment-creating-400.json'; Status = 400; ErrorId = 'AzFoundry.DeploymentCreating' }
        ) {
            Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest {
                New-TestResponse -StatusCode $Status -Content (Get-TestFixture $Fixture)
            }
            { Invoke-Test } | Should -Throw -ErrorId "$ErrorId,Invoke-AzFoundryRequest"
        }
    }

    Context 'secret redaction (end to end, Invoke-WebRequest mocked)' {
        It 'never shows the key in verbose, debug or error output' {
            Mock -ModuleName PwshAzureFoundry Start-Sleep {}
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                New-TestWebResponse -StatusCode 401 `
                    -Content ('{"error":{"code":"401","message":"Access denied for key ' + $script:testKey + '"}}')
            }

            $streams = $null
            $failure = $null
            try {
                $streams = InModuleScope PwshAzureFoundry -Parameters @{ K = $script:testKey } {
                    param($K)
                    $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
                    $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $K
                    Invoke-AzFoundryRequest -Connection $connection -Path '/openai/v1/chat/completions' `
                        -Body @{ model = 'm' } -Verbose -Debug 4>&1 5>&1
                }
            }
            catch {
                $failure = $_
            }

            $failure | Should -Not -BeNullOrEmpty
            $failure.CategoryInfo.Category | Should -Be 'AuthenticationError'
            $logged = @($streams) + @($failure.Exception.Message, $failure.ErrorDetails.Message,
                $failure.Exception.Data['AzFoundryError'].Message, $failure.TargetObject, ($failure | Out-String))
            ($logged -join "`n") | Should -Not -Match ([regex]::Escape($script:testKey))
            $failure.Exception.Message | Should -Match 'Access denied for key \*\*\*'
        }

        It 'masks the api-key header in -Debug on a successful call' {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode 200 -Content '{}' }
            $output = InModuleScope PwshAzureFoundry -Parameters @{ K = $script:testKey } {
                param($K)
                $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
                $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $K
                Invoke-AzFoundryRequest -Connection $connection -Path '/openai/v1/chat/completions' -Body @{ a = 1 } `
                    -Debug 5>&1
            }
            $text = ($output | Where-Object { $_ -is [System.Management.Automation.DebugRecord] }).Message -join "`n"
            $text | Should -Match 'api-key: \*\*\*'
            $text | Should -Not -Match ([regex]::Escape($script:testKey))
        }
    }
}
