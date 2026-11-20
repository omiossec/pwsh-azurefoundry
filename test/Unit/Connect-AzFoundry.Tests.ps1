#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:testKey = 'k3y-SECRET-0123456789abcdef'
    $script:subscription = '00000000-0000-0000-0000-000000000000'
    $script:accountPath = "/subscriptions/$script:subscription/resourceGroups/rg-test/providers/" +
    'Microsoft.CognitiveServices/accounts/test-foundry'

    function Get-TestSession {
        InModuleScope PwshAzureFoundry { $script:AzFoundryConnection }
    }

    function Get-TestKey {
        param($Connection)
        [System.Net.NetworkCredential]::new('', $Connection.ApiKey).Password
    }

    function Mock-TestAzContext {
        Mock -ModuleName PwshAzureFoundry Import-AzFoundryAzAccounts {}
        Mock -ModuleName PwshAzureFoundry Get-AzContext {
            [pscustomobject]@{
                Account      = [pscustomobject]@{ Id = 'user@example.com' }
                Tenant       = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
                Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' }
            }
        }
        Mock -ModuleName PwshAzureFoundry Get-AzAccessToken {
            [pscustomobject]@{
                Token     = ConvertTo-SecureString -String 'entra-token-value' -AsPlainText -Force
                ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
            }
        }
    }
}

Describe 'Connect-AzFoundry' {
    BeforeEach {
        InModuleScope PwshAzureFoundry {
            $script:AzFoundryConnection = $null
            $script:AzFoundryTokenCache = @{}
        }
        # Safety net: a mock that does not match must fail the test, not reach Azure.
        Mock -ModuleName PwshAzureFoundry Invoke-WebRequest { throw "Unit test tried to call $Uri" }
    }

    AfterAll {
        InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
    }

    Context 'ApiKey parameter set' {
        It 'stores the normalised endpoint and the key as a SecureString' {
            Mock -ModuleName PwshAzureFoundry Import-AzFoundryAzAccounts {}
            $key = New-TestSecureString $script:testKey
            Connect-AzFoundry -Endpoint 'https://Lab.OpenAI.azure.com/openai/v1/' -ApiKey $key

            $session = Get-TestSession
            $session.Endpoint | Should -Be 'https://lab.openai.azure.com'
            $session.AuthMode | Should -Be 'ApiKey'
            $session.AccountName | Should -Be 'lab'
            $session.Source | Should -Be 'Session'
            $session.ApiKey | Should -BeOfType [securestring]
            Get-TestKey $session | Should -Be $script:testKey
            Should -Invoke Import-AzFoundryAzAccounts -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'takes the endpoint by position and outputs nothing without -PassThru' {
            $output = Connect-AzFoundry 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k')
            $output | Should -BeNullOrEmpty
            (Get-TestSession).Endpoint | Should -Be 'https://lab.services.ai.azure.com'
        }

        It 'outputs a connection without the key with -PassThru' {
            $result = Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' `
                -ApiKey (New-TestSecureString $script:testKey) -PassThru
            $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.Connection'
            $result.Endpoint | Should -Be 'https://lab.services.ai.azure.com'
            $result.AuthMode | Should -Be 'ApiKey'
            $result.Source | Should -Be 'Session'
            $result.PSObject.Properties.Name | Should -Not -Contain 'ApiKey'
            ($result | Format-List * | Out-String) | Should -Not -Match ([regex]::Escape($script:testKey))
        }

        It 'replaces an existing connection' {
            Connect-AzFoundry -Endpoint 'https://one.services.ai.azure.com' -ApiKey (New-TestSecureString 'k1')
            Connect-AzFoundry -Endpoint 'https://two.services.ai.azure.com' -ApiKey (New-TestSecureString 'k2')
            (Get-TestSession).AccountName | Should -Be 'two'
            Get-TestKey (Get-TestSession) | Should -Be 'k2'
        }

        It 'refuses a non-https endpoint and keeps the current connection' {
            Connect-AzFoundry -Endpoint 'https://one.services.ai.azure.com' -ApiKey (New-TestSecureString 'k1')
            $err = { Connect-AzFoundry -Endpoint 'http://two.services.ai.azure.com' -ApiKey (New-TestSecureString 'k2') } |
                Should -Throw -ErrorId 'AzFoundryEndpointNotHttps,Connect-AzFoundry' -PassThru
            $err.CategoryInfo.Category | Should -Be 'InvalidArgument'
            (Get-TestSession).AccountName | Should -Be 'one'
        }

        It 'changes nothing with -WhatIf' {
            Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'k') -WhatIf
            Get-TestSession | Should -BeNullOrEmpty
        }

        It 'shows the endpoint but never the key in -Verbose' {
            $verbose = Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' `
                -ApiKey (New-TestSecureString $script:testKey) -Verbose 4>&1
            ($verbose.Message -join "`n") | Should -Match 'Connected to https://lab\.services\.ai\.azure\.com \(ApiKey\)'
            ($verbose.Message -join "`n") | Should -Not -Match ([regex]::Escape($script:testKey))
        }
    }

    Context 'EntraId parameter set' {
        It 'stores an EntraId connection with no key and checks the token' {
            Mock-TestAzContext
            Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -UseEntraId

            $session = Get-TestSession
            $session.AuthMode | Should -Be 'EntraId'
            $session.ApiKey | Should -BeNullOrEmpty
            Should -Invoke Get-AzAccessToken -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $ResourceUrl -eq 'https://cognitiveservices.azure.com'
            }
        }

        It 'fails without an Azure sign-in and does not connect' {
            Mock -ModuleName PwshAzureFoundry Import-AzFoundryAzAccounts {}
            Mock -ModuleName PwshAzureFoundry Get-AzContext { $null }
            $err = { Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -UseEntraId } |
                Should -Throw -ErrorId 'AzFoundryAzContextMissing,Connect-AzFoundry' -PassThru
            $err.CategoryInfo.Category | Should -Be 'AuthenticationError'
            $err.ErrorDetails.RecommendedAction | Should -Match 'Connect-AzAccount'
            Get-TestSession | Should -BeNullOrEmpty
        }

        It 'fails when Az.Accounts is missing' {
            Mock -ModuleName PwshAzureFoundry Get-Module {}
            Mock -ModuleName PwshAzureFoundry Get-Module {} -ParameterFilter { $ListAvailable }
            { Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -UseEntraId } |
                Should -Throw -ErrorId 'AzFoundryAzAccountsNotInstalled,Connect-AzFoundry'
        }
    }

    Context 'Arm parameter set' {
        BeforeEach {
            Mock-TestAzContext
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                Get-TestFixture 'arm-account.json' | ConvertFrom-Json
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                [pscustomobject]@{ key1 = 'arm-key-1-0123456789'; key2 = 'arm-key-2-0123456789' }
            } -ParameterFilter { $Path -like '*/listKeys' }
        }

        It 'reads the endpoint and key1 from ARM, with the subscription of the Az context' {
            $result = Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' -PassThru

            Should -Invoke Invoke-AzFoundryArmRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Path -eq $script:accountPath
            }
            Should -Invoke Invoke-AzFoundryArmRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Path -eq "$script:accountPath/listKeys"
            }
            $session = Get-TestSession
            $session.Endpoint | Should -Be 'https://test-foundry.services.ai.azure.com'
            $session.AuthMode | Should -Be 'ApiKey'
            $session.SubscriptionId | Should -Be $script:subscription
            $session.ResourceGroupName | Should -Be 'rg-test'
            $session.AccountName | Should -Be 'test-foundry'
            Get-TestKey $session | Should -Be 'arm-key-1-0123456789'

            $result.ResourceGroupName | Should -Be 'rg-test'
            $result.SubscriptionId | Should -Be $script:subscription
            ($result | Format-List * | Out-String) | Should -Not -Match 'arm-key'
        }

        It 'uses -SubscriptionId when given' {
            $other = '22222222-2222-2222-2222-222222222222'
            Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' -SubscriptionId $other
            (Get-TestSession).SubscriptionId | Should -Be $other
            Should -Invoke Invoke-AzFoundryArmRequest -ModuleName PwshAzureFoundry -ParameterFilter {
                $Path -like "/subscriptions/$other/*"
            }
        }

        It 'does not call listKeys with -UseEntraId' {
            Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' -UseEntraId
            $session = Get-TestSession
            $session.AuthMode | Should -Be 'EntraId'
            $session.ApiKey | Should -BeNullOrEmpty
            $session.ResourceGroupName | Should -Be 'rg-test'
            Should -Invoke Invoke-AzFoundryArmRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly -ParameterFilter {
                $Method -eq 'POST'
            }
        }

        It 'falls back to the OpenAI endpoint, then to properties.endpoint' -ForEach @(
            @{ Endpoints = @{ 'OpenAI Language Model Instance API' = 'https://x.openai.azure.com/' }; Expected = 'https://x.openai.azure.com' }
            @{ Endpoints = $null; Expected = 'https://x.cognitiveservices.azure.com' }
        ) {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                [pscustomobject]@{
                    kind       = 'AIServices'
                    properties = [pscustomobject]@{
                        endpoint  = 'https://x.cognitiveservices.azure.com/'
                        endpoints = if ($Endpoints) { [pscustomobject]$Endpoints }
                    }
                }
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'xx'
            (Get-TestSession).Endpoint | Should -Be $Expected
        }

        It 'refuses keys when local auth is disabled and suggests -UseEntraId' {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                $account = Get-TestFixture 'arm-account.json' | ConvertFrom-Json
                $account.properties.disableLocalAuth = $true
                $account
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            $err = { Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' } |
                Should -Throw -ErrorId 'AzFoundryLocalAuthDisabled,Connect-AzFoundry' -PassThru
            $err.ErrorDetails.RecommendedAction | Should -Match 'UseEntraId'
            Get-TestSession | Should -BeNullOrEmpty
        }

        It 'fails when the resource has no endpoint' {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                [pscustomobject]@{ kind = 'AIServices'; properties = [pscustomobject]@{} }
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            { Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' } |
                Should -Throw -ErrorId 'AzFoundryEndpointMissing,Connect-AzFoundry'
        }

        It 'fails when listKeys returns no key' {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest { } -ParameterFilter { $Path -like '*/listKeys' }
            { Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' } |
                Should -Throw -ErrorId 'AzFoundryKeyMissing,Connect-AzFoundry'
        }

        It 'warns for a resource that is not AIServices' {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                $account = Get-TestFixture 'arm-account.json' | ConvertFrom-Json
                $account.kind = 'TextAnalytics'
                $account
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            $warnings = Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' 3>&1
            ($warnings.Message -join "`n") | Should -Match 'TextAnalytics'
        }

        It 'passes ARM errors through, named after Connect-AzFoundry' {
            Mock -ModuleName PwshAzureFoundry Invoke-AzFoundryArmRequest {
                $response = New-TestResponse -StatusCode 404 `
                    -Content '{"error":{"code":"ResourceNotFound","message":"The Resource was not found."}}'
                $record = & (Get-Module PwshAzureFoundry) {
                    param($Response, $Uri)
                    ConvertTo-AzFoundryErrorRecord -Response $Response -Method GET -Uri $Uri
                } $response "https://management.azure.com$Path"
                $PSCmdlet.ThrowTerminatingError($record)
            } -ParameterFilter { $Path -notlike '*/listKeys' }
            $err = { Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'nope' } |
                Should -Throw -ErrorId 'AzFoundry.ResourceNotFound,Connect-AzFoundry' -PassThru
            $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
        }

        It 'fails without a subscription in the Az context' {
            Mock -ModuleName PwshAzureFoundry Get-AzContext {
                [pscustomobject]@{ Account = [pscustomobject]@{ Id = 'user@example.com' }; Subscription = $null }
            }
            $err = { Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' } |
                Should -Throw -ErrorId 'AzFoundrySubscriptionMissing,Connect-AzFoundry' -PassThru
            $err.ErrorDetails.RecommendedAction | Should -Match 'SubscriptionId'
        }

        It 'makes no ARM call with -WhatIf' {
            Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' -WhatIf
            Should -Invoke Invoke-AzFoundryArmRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly
            Get-TestSession | Should -BeNullOrEmpty
        }

        It 'validates <Name>' -ForEach @(
            @{ Name = 'AccountName'; Parameters = @{ ResourceGroupName = 'rg'; AccountName = 'bad/name' } }
            @{ Name = 'ResourceGroupName'; Parameters = @{ ResourceGroupName = 'rg/../x'; AccountName = 'ok' } }
            @{ Name = 'SubscriptionId'; Parameters = @{ ResourceGroupName = 'rg'; AccountName = 'ok'; SubscriptionId = 'x' } }
        ) {
            { Connect-AzFoundry @Parameters } | Should -Throw -ErrorId "ParameterArgumentValidationError,Connect-AzFoundry"
        }
    }

    Context 'secret redaction (Arm, end to end with Invoke-WebRequest mocked)' {
        It 'never shows the listKeys key in verbose or debug output' {
            Mock-TestAzContext
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                New-TestWebResponse -StatusCode 200 -Content (Get-TestFixture 'arm-account.json')
            } -ParameterFilter { $Uri -notlike '*/listKeys?*' }
            Mock -ModuleName PwshAzureFoundry Invoke-WebRequest {
                New-TestWebResponse -StatusCode 200 `
                    -Content ('{"key1":"' + $script:testKey + '","key2":"other-SECRET-key-999"}')
            } -ParameterFilter { $Uri -like '*/listKeys?*' }

            $streams = Connect-AzFoundry -ResourceGroupName 'rg-test' -AccountName 'test-foundry' -PassThru `
                -Verbose -Debug 4>&1 5>&1
            $text = ($streams | ForEach-Object { if ($_ -is [System.Management.Automation.InformationalRecord]) {
                        $_.Message } else { $_ | Format-List * | Out-String } }) -join "`n"

            $text | Should -Match 'listKeys'
            $text | Should -Match '"key1":"\*\*\*"'
            $text | Should -Not -Match ([regex]::Escape($script:testKey))
            $text | Should -Not -Match 'other-SECRET-key-999'
            $text | Should -Not -Match 'entra-token-value'
            Get-TestKey (Get-TestSession) | Should -Be $script:testKey
        }
    }
}
