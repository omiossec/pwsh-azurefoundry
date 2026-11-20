#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:modelsJson = Get-TestFixture 'arm-models.json'

    # The models fixture plus extra versions of Mistral-Large-3.
    function Get-ModelsWithVersion {
        param([object[]]$Extra)
        $data = $modelsJson | ConvertFrom-Json -Depth 50
        $mistral = $data.value | Where-Object name -EQ 'Mistral-Large-3'
        foreach ($item in $Extra) {
            $copy = $mistral | ConvertTo-Json -Depth 50 | ConvertFrom-Json -Depth 50
            $copy.version = $item.Version
            $copy.isDefaultVersion = $item.Default
            $data.value += $copy
        }
        $data | ConvertTo-Json -Depth 50
    }
}

AfterAll {
    Clear-TestArm
}

Describe 'Get-AzFoundryModel' {
    BeforeEach {
        Initialize-TestArm
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryUtcNow { [datetimeoffset]'2026-11-20T00:00:00Z' }
        Add-TestArmRoute GET '/accounts/test-foundry/models\?' (New-TestResponse -Content $modelsJson)
    }

    Context 'request' {
        It 'calls GET .../models on ARM with the module api-version' {
            $null = Get-AzFoundryModel @TestArmTarget
            $calls = Get-TestArmCall GET
            $calls.Count | Should -Be 1
            $calls[0].Uri | Should -Be "https://management.azure.com$TestAccountPath/models?api-version=2025-06-01"
            $calls[0].Headers['Authorization'] | Should -Be 'Bearer arm-token-0123456789'
        }

        It 'uses the subscription of the Az context when -SubscriptionId is not given' {
            $null = Get-AzFoundryModel -ResourceGroupName 'rg-test' -AccountName 'test-foundry'
            (Get-TestArmCall GET)[0].Uri | Should -Match '/subscriptions/11111111-1111-1111-1111-111111111111/'
        }

        It 'uses the resource of the session' {
            InModuleScope PwshAzureFoundry {
                $connection = [AzFoundryConnection]::new('https://test-foundry.services.ai.azure.com', 'ApiKey')
                $connection.ResourceGroupName = 'rg-test'
                $connection.SubscriptionId = '00000000-0000-0000-0000-000000000000'
                $script:AzFoundryConnection = $connection
            }
            try {
                $null = Get-AzFoundryModel
                (Get-TestArmCall GET)[0].Uri | Should -BeLike "https://management.azure.com$TestAccountPath/models?*"
            } finally {
                InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
            }
        }

        It 'fails with <Case>' -ForEach @(
            @{ Case = 'no resource and no session'; Splat = @{} }
            @{ Case = 'a resource group without account'; Splat = @{ ResourceGroupName = 'rg-test' } }
        ) {
            { Get-AzFoundryModel @Splat } | Should -Throw -ErrorId 'AzFoundryArmTargetMissing,Get-AzFoundryModel'
            Get-TestArmCall | Should -BeNullOrEmpty
        }
    }

    Context 'mapping' {
        It 'maps the ARM fields' {
            $model = Get-AzFoundryModel @TestArmTarget -Name 'text-embedding-3-small'
            $model.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.Model'
            $model.Format | Should -Be 'OpenAI'
            $model.Publisher | Should -Be 'OpenAI'
            $model.Version | Should -Be '1'
            $model.IsDefaultVersion | Should -BeTrue
            $model.LifecycleStatus | Should -Be 'GenerallyAvailable'
            $model.DeprecationDate | Should -Be ([datetimeoffset]'2028-02-09T00:00:00Z')
            $model.IsDeprecated | Should -BeFalse
            $model.Skus | Should -Be @('GlobalStandard', 'DataZoneStandard')
            $model.SkuCapacity['GlobalStandard'].Maximum | Should -Be 1000000
            $model.Tasks | Should -Be @('embeddings')
            $model.Capabilities['embeddingsMaxInputs'] | Should -Be '2048'
            $model.ResourceGroupName | Should -Be 'rg-test'
            $model.AccountName | Should -Be 'test-foundry'
            $model.SubscriptionId | Should -Be $TestSubscriptionId
        }

        It 'takes the publisher when the item has one' {
            (Get-AzFoundryModel @TestArmTarget -Name 'Mistral-Large-3').Publisher | Should -Be 'Mistral AI'
        }
    }

    Context 'filters' {
        It 'leaves out deprecated models by default' {
            $names = (Get-AzFoundryModel @TestArmTarget).Name
            $names | Should -Not -Contain 'sora-2'
            $names.Count | Should -Be 6
        }

        It 'includes them with -IncludeDeprecated' {
            (Get-AzFoundryModel @TestArmTarget -IncludeDeprecated).Name | Should -Contain 'sora-2'
        }

        It 'treats a passed deprecation date as deprecated' {
            Mock -ModuleName PwshAzureFoundry Get-AzFoundryUtcNow { [datetimeoffset]'2027-02-01T00:00:00Z' }
            $names = (Get-AzFoundryModel @TestArmTarget).Name
            $names | Should -Not -Contain 'tts'
            $names | Should -Contain 'Microsoft-Decision-1'
        }

        It 'filters with <Filter>' -ForEach @(
            @{ Filter = '-Name wildcard'; Splat = @{ Name = 'Microsoft-Decision*' }
                Expected = @('Microsoft-Decision-1', 'Microsoft-Decision-1.1') }
            @{ Filter = '-Format'; Splat = @{ Format = 'Mistral*' }; Expected = @('Mistral-Large-3') }
            @{ Filter = '-Publisher alias'; Splat = @{ Publisher = 'Cohere' }; Expected = @('Cohere-embed-v3-english') }
            @{ Filter = '-Sku'; Splat = @{ Sku = 'Standard' }; Expected = @('tts') }
            @{ Filter = '-Task'; Splat = @{ Task = 'embeddings' }; Expected = @('text-embedding-3-small') }
            @{ Filter = '-Task decision'; Splat = @{ Task = 'decision' }
                Expected = @('Microsoft-Decision-1', 'Microsoft-Decision-1.1') }
        ) {
            @((Get-AzFoundryModel @TestArmTarget @Splat).Name) | Should -Be $Expected
        }

        It 'keeps only the models with every -Task (capability value true)' {
            # The decision models have chatCompletion = 'false'.
            Get-AzFoundryModel @TestArmTarget -Task 'chatCompletion', 'decision' | Should -BeNullOrEmpty
            (Get-AzFoundryModel @TestArmTarget -Task 'chatCompletion').Name | Should -Be 'Mistral-Large-3'
        }

        It 'writes a non-terminating error for an exact name that does not exist' {
            $result = Get-AzFoundryModel @TestArmTarget -Name 'no-such-model' -ErrorVariable err -ErrorAction SilentlyContinue
            $result | Should -BeNullOrEmpty
            $err[0].FullyQualifiedErrorId | Should -Be 'AzFoundryModelNotFound,Get-AzFoundryModel'
            $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
        }

        It 'hints at -IncludeDeprecated for a deprecated model' {
            $null = Get-AzFoundryModel @TestArmTarget -Name 'sora-2' -ErrorVariable err -ErrorAction SilentlyContinue
            $err[0].ErrorDetails.RecommendedAction | Should -Match 'IncludeDeprecated'
        }

        It 'returns nothing, without error, when a wildcard matches nothing' {
            Get-AzFoundryModel @TestArmTarget -Name 'zzz*' -ErrorVariable err | Should -BeNullOrEmpty
            $err | Should -BeNullOrEmpty
        }
    }

    Context 'versions' {
        It 'returns the default version when one is flagged' {
            Add-TestArmRoute GET '/models\?' (New-TestResponse -Content (Get-ModelsWithVersion @(
                        @{ Version = '2'; Default = $false })))
            $global:AzFoundryTestArmRoutes.RemoveAt(0)
            (Get-AzFoundryModel @TestArmTarget -Name 'Mistral-Large-3').Version | Should -Be '1'
        }

        It 'returns the highest version when none is flagged' {
            $json = (Get-ModelsWithVersion @(@{ Version = '10'; Default = $false }; @{ Version = '9'; Default = $false })) `
                -replace '"isDefaultVersion":\s*true', '"isDefaultVersion": false'
            Add-TestArmRoute GET '/models\?' (New-TestResponse -Content $json)
            $global:AzFoundryTestArmRoutes.RemoveAt(0)
            (Get-AzFoundryModel @TestArmTarget -Name 'Mistral-Large-3').Version | Should -Be '10'
        }

        It 'returns every version with -AllVersions' {
            Add-TestArmRoute GET '/models\?' (New-TestResponse -Content (Get-ModelsWithVersion @(
                        @{ Version = '2'; Default = $false })))
            $global:AzFoundryTestArmRoutes.RemoveAt(0)
            (Get-AzFoundryModel @TestArmTarget -Name 'Mistral-Large-3' -AllVersions).Version | Should -Be @('1', '2')
        }
    }
}

Describe 'Select-AzFoundryLatestModel' {
    It 'picks <Expected> from <Versions>' -ForEach @(
        @{ Versions = @('9', '10'); Expected = '10' }
        @{ Versions = @('001', '2'); Expected = '2' }
        @{ Versions = @('2024-07-18', '2025-12-08', '2025-04-14'); Expected = '2025-12-08' }
        @{ Versions = @('1.9', '1.10'); Expected = '1.10' }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Versions = $Versions; Expected = $Expected } {
            param($Versions, $Expected)
            $models = foreach ($version in $Versions) {
                [pscustomobject]@{ Format = 'OpenAI'; Name = 'm'; Version = $version; IsDefaultVersion = $false }
            }
            ($models | Select-AzFoundryLatestModel).Version | Should -Be $Expected
        }
    }

    It 'keeps one model per format and name' {
        InModuleScope PwshAzureFoundry {
            $models = @(
                [pscustomobject]@{ Format = 'OpenAI'; Name = 'a'; Version = '1'; IsDefaultVersion = $true }
                [pscustomobject]@{ Format = 'OpenAI'; Name = 'A'; Version = '2'; IsDefaultVersion = $false }
                [pscustomobject]@{ Format = 'Other'; Name = 'a'; Version = '1'; IsDefaultVersion = $false }
            )
            $result = @($models | Select-AzFoundryLatestModel)
            $result.Count | Should -Be 2
            $result[0].Version | Should -Be '1'
        }
    }
}
