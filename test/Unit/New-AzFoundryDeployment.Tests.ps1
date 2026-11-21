#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:putSync = New-TestResponse -StatusCode 201 -Content (Get-TestFixture 'arm-deployment-put-sync.json')
    $script:asyncCreating = Get-TestFixtureResponse 'arm-deployment-put-async'
    $script:asyncDone = New-TestResponse -Content ((Get-TestFixture 'arm-deployment-put-async.json') `
            -replace '"provisioningState":\s*"Creating"', '"provisioningState": "Succeeded"')
}

AfterAll {
    Clear-TestArm
}

Describe 'New-AzFoundryDeployment' {
    BeforeEach {
        Initialize-TestArm
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryUtcNow { [datetimeoffset]'2026-11-20T00:00:00Z' }
        Mock -ModuleName PwshAzureFoundry Wait-AzFoundryDeploymentReady { $true }
        Add-TestArmRoute GET '/models\?' (New-TestResponse -Content (Get-TestFixture 'arm-models.json'))
        Add-TestArmRoute GET '/deployments\?' (New-TestResponse -Content (Get-TestFixture 'arm-deployments.json'))
        Add-TestArmRoute PUT '/deployments/[^/?]+\?' $putSync
    }

    Context 'request' {
        It 'reads the catalogue and sends the PUT body of the spike' {
            $result = New-AzFoundryDeployment @TestArmTarget -ModelName 'text-embedding-3-small'

            $put = Get-TestArmCall PUT
            $put.Count | Should -Be 1
            $put[0].Uri | Should -Be ("https://management.azure.com$TestAccountPath/deployments/" +
                'text-embedding-3-small?api-version=2025-06-01')
            ConvertTo-TestCanonicalJson $put[0].Body | Should -Be (ConvertTo-TestCanonicalJson @{
                    sku        = @{ name = 'GlobalStandard'; capacity = 1 }
                    properties = @{ model = @{ format = 'OpenAI'; name = 'text-embedding-3-small'; version = '1' } }
                })
            $result.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.Deployment'
            $result.ProvisioningState | Should -Be 'Succeeded'
        }

        It 'maps -Name, -SkuName, -Capacity and -RaiPolicyName' {
            $null = New-AzFoundryDeployment @TestArmTarget -ModelName 'Mistral-Large-3' -Name 'chat' `
                -SkuName DataZoneStandard -Capacity 20 -RaiPolicyName 'Strict'
            $put = (Get-TestArmCall PUT)[0]
            $put.Uri | Should -Match '/deployments/chat\?'
            $put.Body.sku.name | Should -Be 'DataZoneStandard'
            $put.Body.sku.capacity | Should -Be 20
            $put.Body.properties.raiPolicyName | Should -Be 'Strict'
            $put.Body.properties.model.format | Should -Be 'Mistral AI'
        }

        It 'does not read the catalogue when -ModelVersion and -ModelFormat are given' {
            $null = New-AzFoundryDeployment @TestArmTarget -ModelName 'gpt-x' -ModelVersion '2' -ModelFormat 'OpenAI'
            Get-TestArmCall GET '/models' | Should -BeNullOrEmpty
            (Get-TestArmCall PUT)[0].Body.properties.model.version | Should -Be '2'
        }

        It 'sends no PUT with -WhatIf' {
            $result = New-AzFoundryDeployment @TestArmTarget -ModelName 'text-embedding-3-small' -WhatIf
            $result | Should -BeNullOrEmpty
            Get-TestArmCall PUT | Should -BeNullOrEmpty
            Should -Invoke Wait-AzFoundryDeploymentReady -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'takes the model and the resource from a piped Get-AzFoundryModel object' {
            $null = Get-AzFoundryModel @TestArmTarget -Name 'text-embedding-3-small' | New-AzFoundryDeployment
            $put = (Get-TestArmCall PUT)[0]
            $put.Uri | Should -BeLike "https://management.azure.com$TestAccountPath/deployments/text-embedding-3-small?*"
            $put.Body.properties.model.version | Should -Be '1'
            # The catalogue was read once, by Get-AzFoundryModel.
            (Get-TestArmCall GET '/models').Count | Should -Be 1
        }
    }

    Context 'waiting' {
        It 'checks readiness with the capabilities of the deployment' {
            $null = New-AzFoundryDeployment @TestArmTarget -ModelName 'text-embedding-3-small'
            Should -Invoke Wait-AzFoundryDeploymentReady -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'text-embedding-3-small' -and $Task -contains 'embeddings' -and $Target.AccountName -eq 'test-foundry'
            }
        }

        It 'skips the readiness check with -SkipReadinessCheck' {
            $null = New-AzFoundryDeployment @TestArmTarget -ModelName 'text-embedding-3-small' -SkipReadinessCheck
            Should -Invoke Wait-AzFoundryDeploymentReady -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'polls an asynchronous (partner) deployment until it succeeds' {
            Add-TestArmRoute GET '/operationResults/' @(
                (New-TestResponse -Content (Get-TestFixture 'arm-operation-running.json')),
                (New-TestResponse -Content (Get-TestFixture 'arm-operation-succeeded.json')))
            Add-TestArmRoute GET '/deployments/Cohere-embed-v3-english\?' $asyncDone
            $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                    Method = 'PUT'; Pattern = '/deployments/Cohere-embed-v3-english\?'
                    Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@($asyncCreating))
                })

            $result = New-AzFoundryDeployment @TestArmTarget -ModelName 'Cohere-embed-v3-english'

            (Get-TestArmCall GET '/operationResults/').Count | Should -Be 2
            $result.ProvisioningState | Should -Be 'Succeeded'
            $result.Format | Should -Be 'Cohere'
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 2
        }

        It 'returns at once with -NoWait' {
            $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                    Method = 'PUT'; Pattern = '/deployments/Cohere-embed-v3-english\?'
                    Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@($asyncCreating))
                })
            $result = New-AzFoundryDeployment @TestArmTarget -ModelName 'Cohere-embed-v3-english' -NoWait
            $result.ProvisioningState | Should -Be 'Creating'
            Get-TestArmCall GET '/operationResults/' | Should -BeNullOrEmpty
            Should -Invoke Wait-AzFoundryDeploymentReady -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }
    }

    Context 'errors' {
        It 'refuses to replace an existing deployment' {
            { New-AzFoundryDeployment @TestArmTarget -ModelName 'Mistral-Large-3' } |
                Should -Throw -ErrorId 'AzFoundryDeploymentExists,New-AzFoundryDeployment'
            Get-TestArmCall PUT | Should -BeNullOrEmpty
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'a model missing from the catalogue'; Splat = @{ ModelName = 'no-such-model' }
                ErrorId = 'AzFoundryModelNotFound' }
            @{ Case = 'a SKU the model does not offer'; Splat = @{ ModelName = 'Cohere-embed-v3-english'; SkuName = 'Standard' }
                ErrorId = 'AzFoundrySkuNotAvailable' }
            @{ Case = 'a capacity above the SKU maximum'; Splat = @{ ModelName = 'Cohere-embed-v3-english'; Capacity = 2 }
                ErrorId = 'AzFoundryCapacityTooHigh' }
            @{ Case = 'a model name that is not a deployment name'; Splat = @{ ModelName = 'a b'; ModelVersion = '1'; ModelFormat = 'X' }
                ErrorId = 'AzFoundryDeploymentNameInvalid' }
        ) {
            { New-AzFoundryDeployment @TestArmTarget @Splat } | Should -Throw -ErrorId "$ErrorId,New-AzFoundryDeployment"
            Get-TestArmCall PUT | Should -BeNullOrEmpty
        }

        It 'warns when the model is deprecated' {
            $output = New-AzFoundryDeployment @TestArmTarget -ModelName 'sora-2' -SkipReadinessCheck 3>&1
            $warning = $output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            "$warning" | Should -BeLike '*sora-2 2025-12-08 is deprecated (inference until 2026-11-02)*'
        }

        It 'adds a hint to a marketplace error' {
            $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                    Method = 'PUT'; Pattern = '/deployments/'
                    Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@(
                            (New-TestResponse -StatusCode 400 -Content ('{"error":{"code":"MarketplacePurchaseEligibilityFailed",' +
                                '"message":"Marketplace purchase eligibility check returned errors."}}'))))
                })
            $err = { New-AzFoundryDeployment @TestArmTarget -ModelName 'Cohere-embed-v3-english' } |
                Should -Throw -PassThru
            $err.FullyQualifiedErrorId | Should -Be 'AzFoundryMarketplaceTerms,New-AzFoundryDeployment'
            $err.ErrorDetails.RecommendedAction | Should -Match 'Foundry portal'
            $err.Exception.Message | Should -Match 'Marketplace purchase'
        }

        It 'passes other ARM errors through without the token' {
            $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                    Method = 'PUT'; Pattern = '/deployments/'
                    Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@(
                            (New-TestResponse -StatusCode 400 -Content '{"error":{"code":"InsufficientQuota","message":"Quota exceeded."}}')))
                })
            $err = { New-AzFoundryDeployment @TestArmTarget -ModelName 'text-embedding-3-small' } | Should -Throw -PassThru
            $err.CategoryInfo.Category | Should -Be 'InvalidArgument'
            $err.Exception.Message | Should -Match 'Quota exceeded'
            $err.ToString() | Should -Not -Match 'arm-token-0123456789'
        }
    }
}

Describe 'Wait-AzFoundryDeploymentReady' {
    BeforeAll {
        $script:readyTarget = [pscustomobject]@{
            SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroupName = 'rg-test'; AccountName = 'test-foundry'
        }
        function Invoke-Ready {
            param([string[]]$Task, [int]$TimeoutSec = 60)
            InModuleScope PwshAzureFoundry -Parameters @{ T = $readyTarget; Task = $Task; Timeout = $TimeoutSec } {
                param($T, $Task, $Timeout)
                Wait-AzFoundryDeploymentReady -Target $T -Name 'dep' -Task $Task -TimeoutSec $Timeout
            }
        }
        $script:notFound = New-TestResponse -StatusCode 404 -Content (Get-TestFixture 'error-deployment-not-found.json')
    }

    BeforeEach {
        Initialize-TestArm
        Connect-AzFoundry -Endpoint 'https://test-foundry.services.ai.azure.com' -ApiKey (New-TestSecureString 'ready-key-0123')
    }

    It 'probes <Route> for <Task>' -ForEach @(
        @{ Task = @('embeddings'); Route = '/openai/v1/embeddings' }
        @{ Task = @('chatCompletion'); Route = '/openai/v1/chat/completions' }
        @{ Task = @('chatCompletion', 'decision'); Route = '/providers/microsoft/v1/systemone' }
    ) {
        Add-TestArmRoute POST '.' (New-TestResponse -Content '{}')
        Invoke-Ready -Task $Task | Should -BeTrue
        $calls = Get-TestArmCall POST
        $calls.Count | Should -Be 1
        $calls[0].Uri | Should -Be "https://test-foundry.services.ai.azure.com$Route"
        $calls[0].Body.model | Should -Be 'dep'
        $calls[0].Headers['api-key'] | Should -Be 'ready-key-0123'
    }

    It 'does not probe a model with no chat, embeddings or decision capability' {
        Invoke-Ready -Task @('audio') | Should -BeTrue
        Get-TestArmCall | Should -BeNullOrEmpty
    }

    It 'waits while the data plane answers 404 or DeploymentCreating' {
        Add-TestArmRoute POST '/embeddings' @(
            $notFound,
            (New-TestResponse -StatusCode 400 -Content (Get-TestFixture 'error-deployment-creating-400.json')),
            (New-TestResponse -Content (Get-TestFixture 'embedding.json')))
        Invoke-Ready -Task 'embeddings' | Should -BeTrue
        (Get-TestArmCall POST).Count | Should -Be 3
        Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 2 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'warns and returns false after -TimeoutSec' {
        Add-TestArmRoute POST '/embeddings' $notFound
        $output = Invoke-Ready -Task 'embeddings' -TimeoutSec 4 3>&1
        ($output | Where-Object { $_ -is [bool] }) | Should -BeFalse
        "$($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })" |
            Should -BeLike '*does not answer on the data plane yet after 4 s*'
    }

    It 'warns and stops on another error' {
        Add-TestArmRoute POST '/embeddings' (New-TestResponse -StatusCode 401 -Content (Get-TestFixture 'error-401.json'))
        $output = Invoke-Ready -Task 'embeddings' 3>&1
        ($output | Where-Object { $_ -is [bool] }) | Should -BeFalse
        "$($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })" |
            Should -BeLike '*readiness check of dep failed*'
        (Get-TestArmCall POST).Count | Should -Be 1
    }

    It 'builds a connection from ARM when the session is another resource' {
        Connect-AzFoundry -Endpoint 'https://other.services.ai.azure.com' -ApiKey (New-TestSecureString 'other-key')
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryArmConnection {
            & (Get-Module PwshAzureFoundry) {
                $connection = [AzFoundryConnection]::new('https://test-foundry.services.ai.azure.com', 'ApiKey')
                $connection.ApiKey = ConvertTo-SecureString 'arm-key-0123' -AsPlainText -Force
                $connection
            }
        }
        Add-TestArmRoute POST '.' (New-TestResponse -Content '{}')
        Invoke-Ready -Task 'embeddings' | Should -BeTrue
        (Get-TestArmCall POST)[0].Headers['api-key'] | Should -Be 'arm-key-0123'
        Should -Invoke Get-AzFoundryArmConnection -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $AccountName -eq 'test-foundry' -and $ResourceGroupName -eq 'rg-test' -and -not $UseEntraId
        }
    }

    It 'probes with Entra ID and never reads the keys when the session uses Entra ID' {
        InModuleScope PwshAzureFoundry {
            $script:AzFoundryConnection = [AzFoundryConnection]::new('https://other.services.ai.azure.com', 'EntraId')
        }
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryArmConnection {
            & (Get-Module PwshAzureFoundry) {
                [AzFoundryConnection]::new('https://test-foundry.services.ai.azure.com', 'EntraId')
            }
        }
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryAuthHeader { @{ Authorization = 'Bearer entra-token' } }
        Add-TestArmRoute POST '.' (New-TestResponse -Content '{}')
        Invoke-Ready -Task 'embeddings' | Should -BeTrue
        Should -Invoke Get-AzFoundryArmConnection -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $AccountName -eq 'test-foundry' -and $UseEntraId
        }
        Should -Invoke Get-AzFoundryArmConnection -ModuleName PwshAzureFoundry -Times 0 -Exactly -ParameterFilter {
            -not $UseEntraId
        }
    }
}
