#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    function Send-Test {
        param([hashtable]$Parameters)
        InModuleScope PwshAzureFoundry -Parameters @{ P = $Parameters } {
            param($P)
            Send-AzFoundryHttpRequest @P
        }
    }

    $script:uri = 'https://lab.openai.azure.com/openai/v1/chat/completions'
}

Describe 'Send-AzFoundryHttpRequest' {
    BeforeEach {
        Mock -ModuleName PwshAzureFoundry Start-Sleep {}
        Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
            New-TestWebResponse -StatusCode 200 -Content '{"ok":true}' -Headers @{ 'x-ratelimit-remaining-requests' = '19' }
        }
    }

    It 'returns status, flattened headers and content' {
        $result = Send-Test @{ Uri = $script:uri; Method = 'POST'; Body = '{}' }
        $result.StatusCode | Should -Be 200
        $result.Content | Should -Be '{"ok":true}'
        $result.Headers['X-RateLimit-Remaining-Requests'] | Should -Be '19'
    }

    It 'sends the body as UTF-8 JSON with the module User-Agent, no redirects and the timeout' {
        Send-Test @{ Uri = $script:uri; Method = 'POST'; Body = '{"text":"café"}'; TimeoutSec = 30 } | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            [System.Text.Encoding]::UTF8.GetString($Body) -eq '{"text":"café"}' -and
            $ContentType -eq 'application/json; charset=utf-8' -and
            $UserAgent -like 'PwshAzureFoundry/* PowerShell/*' -and
            $SkipHttpErrorCheck -and $MaximumRedirection -eq 0 -and
            $OperationTimeoutSeconds -eq 30 -and $ConnectionTimeoutSeconds -eq 30
        }
    }

    It 'sends no body or content type when none is given' {
        Send-Test @{ Uri = $script:uri; Method = 'GET' } | Out-Null
        Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $null -eq $Body -and -not $ContentType
        }
    }

    It 'decodes a byte[] body' {
        Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = [System.Text.Encoding]::UTF8.GetBytes('{"a":1}') }
        }
        (Send-Test @{ Uri = $script:uri }).Content | Should -Be '{"a":1}'
    }

    It 'refuses a non-https URI before sending' {
        $err = { Send-Test @{ Uri = 'http://lab.openai.azure.com/x' } } |
            Should -Throw -ErrorId 'AzFoundryUriNotHttps,Send-AzFoundryHttpRequest' -PassThru
        $err.CategoryInfo.Category | Should -Be 'SecurityError'
        Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly
    }

    Context 'retries' {
        It 'retries a 429 after Retry-After and returns the success' {
            $script:calls = 0
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                $script:calls++
                if ($script:calls -eq 1) {
                    New-TestWebResponse -StatusCode 429 -Content (Get-TestFixture 'synthetic-error-429.json') `
                        -Headers @{ 'Retry-After' = '6' }
                }
                else {
                    New-TestWebResponse -StatusCode 200 -Content '{}'
                }
            }
            (Send-Test @{ Uri = $script:uri; Method = 'POST' }).StatusCode | Should -Be 200
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 2 -Exactly
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Milliseconds -eq 6000
            }
        }

        It 'retries <Status> up to MaxRetry times, then returns the last response' -ForEach @(
            @{ Status = 500 }, @{ Status = 502 }, @{ Status = 503 }, @{ Status = 504 }
        ) {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode $Status -Content '' }
            (Send-Test @{ Uri = $script:uri; MaxRetry = 2 }).StatusCode | Should -Be $Status
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 3 -Exactly
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 2 -Exactly
        }

        It 'does not retry a POST on <Status>: the inference may already have run and been billed' -ForEach @(
            @{ Status = 500 }, @{ Status = 502 }, @{ Status = 503 }, @{ Status = 504 }
        ) {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode $Status -Content '' }
            (Send-Test @{ Uri = $script:uri; Method = 'POST'; Body = '{}' }).StatusCode | Should -Be $Status
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'retries <Method> on 503 (idempotent)' -ForEach @(@{ Method = 'PUT' }, @{ Method = 'DELETE' }) {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode 503 -Content '' }
            Send-Test @{ Uri = $script:uri; Method = $Method; MaxRetry = 1 } | Out-Null
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 2 -Exactly
        }

        It 'uses the module default of 3 retries' {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode 503 }
            Send-Test @{ Uri = $script:uri } | Out-Null
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 4 -Exactly
        }

        It 'does not retry <Status>' -ForEach @(@{ Status = 400 }, @{ Status = 401 }, @{ Status = 404 }, @{ Status = 422 }) {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { New-TestWebResponse -StatusCode $Status -Content '{}' }
            (Send-Test @{ Uri = $script:uri }).StatusCode | Should -Be $Status
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }
    }

    Context 'network failures' {
        It 'maps a timeout to OperationTimeout and does not retry it' {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                throw [System.Threading.Tasks.TaskCanceledException]::new(
                    'The request was canceled due to the configured HttpClient.Timeout of 120 seconds elapsing.',
                    [System.TimeoutException]::new('The operation was canceled.'))
            }
            $err = { Send-Test @{ Uri = $script:uri; TimeoutSec = 120 } } |
                Should -Throw -ErrorId 'AzFoundryRequestTimeout,Send-AzFoundryHttpRequest' -PassThru
            $err.CategoryInfo.Category | Should -Be 'OperationTimeout'
            $err.Exception.Message | Should -Match 'timed out after 120 s'
            Should -Invoke Invoke-WebRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
        }

        It 'maps a connection failure to ConnectionError' {
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                throw [System.Net.Http.HttpRequestException]::new('No such host is known. (nope.openai.azure.com:443)')
            }
            $err = { Send-Test @{ Uri = 'https://nope.openai.azure.com/openai/v1/chat/completions' } } |
                Should -Throw -ErrorId 'AzFoundryConnectionFailed,Send-AzFoundryHttpRequest' -PassThru
            $err.CategoryInfo.Category | Should -Be 'ConnectionError'
            $err.Exception.Message | Should -Match 'No such host'
            $err.Exception.InnerException | Should -BeOfType [System.Net.Http.HttpRequestException]
        }
    }

    Context 'logging' {
        It 'shows method, URI, status and elapsed time in -Verbose' {
            $verbose = InModuleScope PwshAzureFoundry -Parameters @{ U = $script:uri } {
                param($U)
                Send-AzFoundryHttpRequest -Uri $U -Method POST -Verbose 4>&1
            } | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
            $verbose.Message | Should -Match '^POST https://lab\.openai\.azure\.com/openai/v1/chat/completions -> 200 in \d+ ms$'
        }

        It 'masks auth headers and secrets in -Debug and never logs a signed query string' {
            $output = InModuleScope PwshAzureFoundry {
                $headers = @{ 'api-key' = 'SECRET-KEY-0123456789'; 'x-custom' = 'visible' }
                Send-AzFoundryHttpRequest -Uri 'https://lab.openai.azure.com/x?api-version=1&sig=SIGNATURE' `
                    -Method POST -Headers $headers -Body '{"echo":"SECRET-KEY-0123456789"}' -Debug -Verbose 4>&1 5>&1
            }
            $text = ($output | Where-Object { $_ -is [System.Management.Automation.InformationalRecord] }).Message -join "`n"
            $text | Should -Match 'api-key: \*\*\*'
            $text | Should -Match 'x-custom: visible'
            $text | Should -Match 'api-version=1&<redacted>'
            $text | Should -Not -Match 'SECRET-KEY-0123456789'
            $text | Should -Not -Match 'SIGNATURE'
        }
    }
}
