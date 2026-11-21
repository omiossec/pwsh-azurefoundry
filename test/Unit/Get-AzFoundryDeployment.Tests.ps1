#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:deploymentsJson = Get-TestFixture 'arm-deployments.json'
    $script:mistralJson = ($deploymentsJson | ConvertFrom-Json -Depth 50).value[0] | ConvertTo-Json -Depth 50
    $script:notFoundJson = '{"error":{"code":"DeploymentNotFound","message":"The deployment nope was not found."}}'
}

AfterAll {
    Clear-TestArm
}

Describe 'Get-AzFoundryDeployment' {
    BeforeEach {
        Initialize-TestArm
        Add-TestArmRoute GET '/deployments\?' (New-TestResponse -Content $deploymentsJson)
        Add-TestArmRoute GET '/deployments/Mistral-Large-3\?' (New-TestResponse -Content $mistralJson)
        Add-TestArmRoute GET '/deployments/nope\?' (New-TestResponse -StatusCode 404 -Content $notFoundJson)
    }

    It 'lists the deployments with GET .../deployments, sorted by name' {
        $result = @(Get-AzFoundryDeployment @TestArmTarget)
        (Get-TestArmCall GET)[0].Uri | Should -Be "https://management.azure.com$TestAccountPath/deployments?api-version=2025-06-01"
        $result.Name | Should -Be @('Decision-1.1', 'Mistral-Large-3')
    }

    It 'maps the ARM fields' {
        $deployment = Get-AzFoundryDeployment @TestArmTarget | Where-Object Name -EQ 'Mistral-Large-3'
        $deployment.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.Deployment'
        $deployment.ModelName | Should -Be 'Mistral-Large-3'
        $deployment.Version | Should -Be '1'
        $deployment.Format | Should -Be 'Mistral AI'
        $deployment.Sku | Should -Be 'GlobalStandard'
        $deployment.Capacity | Should -Be 20
        $deployment.ProvisioningState | Should -Be 'Succeeded'
        $deployment.RaiPolicy | Should -Be 'Microsoft.DefaultV2'
        $deployment.Capabilities['chatCompletion'] | Should -Be 'true'
        $deployment.CreatedAt | Should -BeOfType [datetimeoffset]
        $deployment.CreatedAt | Should -Be ([datetimeoffset]'2026-11-16T21:52:32.9948442Z')
        $deployment.CreatedAt.Offset | Should -Be ([timespan]::Zero)
        $deployment.Id | Should -BeLike '*/deployments/Mistral-Large-3'
        $deployment.ResourceGroupName | Should -Be 'rg-test'
        $deployment.AccountName | Should -Be 'test-foundry'
        $deployment.SubscriptionId | Should -Be $TestSubscriptionId
    }

    It 'reads one deployment with GET .../deployments/{name} when -Name has no wildcard' {
        $deployment = Get-AzFoundryDeployment @TestArmTarget -Name 'Mistral-Large-3'
        $deployment.Name | Should -Be 'Mistral-Large-3'
        @(Get-TestArmCall GET).Uri | Should -Be @(
            "https://management.azure.com$TestAccountPath/deployments/Mistral-Large-3?api-version=2025-06-01")
    }

    It 'filters the list when -Name has a wildcard' {
        (Get-AzFoundryDeployment @TestArmTarget -Name 'dec*').Name | Should -Be 'Decision-1.1'
    }

    It 'writes a non-terminating error for a missing deployment' {
        $output = @(Get-AzFoundryDeployment @TestArmTarget -Name 'nope' -ErrorAction Continue 2>&1)
        $output.Count | Should -Be 1
        $err = $output
        $err[0].FullyQualifiedErrorId | Should -Be 'AzFoundryDeploymentNotFound,Get-AzFoundryDeployment'
        $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
    }

    It 'throws other ARM errors and never shows the token' {
        Add-TestArmRoute GET '/deployments/denied\?' (New-TestResponse -StatusCode 403 `
                -Content '{"error":{"code":"AuthorizationFailed","message":"No access."}}')
        $global:AzFoundryTestArmRoutes.Insert(0, $global:AzFoundryTestArmRoutes[-1])
        $err = { Get-AzFoundryDeployment @TestArmTarget -Name 'denied' } | Should -Throw -PassThru
        $err.CategoryInfo.Category | Should -Be 'PermissionDenied'
        $err.ToString() | Should -Not -Match 'arm-token-0123456789'
    }

    It 'pipes into Invoke-AzFoundryChat (-Model binds from Name)' {
        Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry {
            [pscustomobject]@{
                StatusCode = 200; Headers = @{}
                Content    = (Get-TestFixture 'chat-completion.json' | ConvertFrom-Json)
            }
        }
        Connect-AzFoundry -Endpoint 'https://test-foundry.services.ai.azure.com' -ApiKey (New-TestSecureString 'k-0123')
        $null = Get-AzFoundryDeployment @TestArmTarget | Invoke-AzFoundryChat -Prompt 'hi'
        # The deployment name, not the model name (Microsoft-Decision-1.1).
        Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $Body.model -eq 'Decision-1.1'
        }
        Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $Body.model -eq 'Mistral-Large-3'
        }
    }

    It 'rejects a name made only of dots (<Name>)' -ForEach @(@{ Name = '.' }, @{ Name = '..' }) {
        { Get-AzFoundryDeployment -Name $Name } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'rejects a resource group name that ends with a period' {
        { Get-AzFoundryDeployment -ResourceGroupName 'rg-lab.' } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }
}
