#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    function Get-TestToken {
        param([string]$ResourceUrl = 'https://management.azure.com', [switch]$ForceRefresh)
        InModuleScope PwshAzureFoundry -Parameters @{ R = $ResourceUrl; F = [bool]$ForceRefresh } {
            param($R, $F)
            Get-AzFoundryAccessToken -ResourceUrl $R -ForceRefresh:$F
        }
    }
}

Describe 'Get-AzFoundryAccessToken' {
    BeforeEach {
        InModuleScope PwshAzureFoundry { $script:AzFoundryTokenCache = @{} }
        Mock -ModuleName PwshAzureFoundry Import-AzFoundryAzAccounts {}
        Mock -ModuleName PwshAzureFoundry Get-AzContext {
            [pscustomobject]@{
                Account = [pscustomobject]@{ Id = 'user@example.com' }
                Tenant  = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
            }
        }
        Mock -ModuleName PwshAzureFoundry Get-AzAccessToken {
            [pscustomobject]@{
                Token     = ConvertTo-SecureString -String 'token-1' -AsPlainText -Force
                ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
            }
        }
    }

    It 'returns the token as a SecureString and asks Az.Accounts for a SecureString' {
        $result = Get-TestToken
        $result.Token | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $result.Token).Password | Should -Be 'token-1'
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $ResourceUrl -eq 'https://management.azure.com' -and $AsSecureString
        }
    }

    It 'wraps a plain-text token (older Az.Accounts) in a SecureString' {
        Mock -ModuleName PwshAzureFoundry Get-AzAccessToken {
            [pscustomobject]@{ Token = 'plain-token'; ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1) }
        }
        $result = Get-TestToken
        $result.Token | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $result.Token).Password | Should -Be 'plain-token'
    }

    It 'reuses the cached token' {
        Get-TestToken | Out-Null
        Get-TestToken | Out-Null
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 1 -Exactly
    }

    It 'caches per resource' {
        Get-TestToken -ResourceUrl 'https://management.azure.com' | Out-Null
        Get-TestToken -ResourceUrl 'https://cognitiveservices.azure.com' | Out-Null
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 2 -Exactly
    }

    It 'refreshes a token that expires within 5 minutes' {
        Mock -ModuleName PwshAzureFoundry Get-AzAccessToken {
            [pscustomobject]@{ Token = 'short'; ExpiresOn = [datetimeoffset]::UtcNow.AddMinutes(4) }
        }
        Get-TestToken | Out-Null
        Get-TestToken | Out-Null
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 2 -Exactly
    }

    It 'refreshes when the Azure account changes' {
        Get-TestToken | Out-Null
        Mock -ModuleName PwshAzureFoundry Get-AzContext {
            [pscustomobject]@{
                Account = [pscustomobject]@{ Id = 'other@example.com' }
                Tenant  = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
            }
        }
        Get-TestToken | Out-Null
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 2 -Exactly
    }

    It 'ignores the cache with -ForceRefresh' {
        Get-TestToken | Out-Null
        Get-TestToken -ForceRefresh | Out-Null
        Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 2 -Exactly
    }

    It 'asks for Connect-AzAccount when there is no Azure context' {
        Mock -ModuleName PwshAzureFoundry Get-AzContext {}
        $err = { Get-TestToken } | Should -Throw -ErrorId 'AzFoundryAzContextMissing,Get-AzFoundryAccessToken' -PassThru
        $err.CategoryInfo.Category | Should -Be 'AuthenticationError'
        $err.ErrorDetails.RecommendedAction | Should -Match 'Connect-AzAccount'
    }

    It 'maps a Get-AzAccessToken failure to AuthenticationError' {
        Mock -ModuleName PwshAzureFoundry Get-AzAccessToken { throw 'AADSTS50076: MFA required' }
        $err = { Get-TestToken } | Should -Throw -ErrorId 'AzFoundryTokenFailed,Get-AzFoundryAccessToken' -PassThru
        $err.CategoryInfo.Category | Should -Be 'AuthenticationError'
        $err.Exception.Message | Should -Match 'AADSTS50076'
    }
}
