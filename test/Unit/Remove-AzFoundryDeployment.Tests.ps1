#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

AfterAll {
    Clear-TestArm
}

Describe 'Remove-AzFoundryDeployment' {
    BeforeEach {
        Initialize-TestArm
        Add-TestArmRoute GET '/deployments\?' (New-TestResponse -Content (Get-TestFixture 'arm-deployments.json'))
        Add-TestArmRoute DELETE '/deployments/' (Get-TestFixtureResponse 'arm-deployment-delete-sync')
    }

    It 'is a High impact ShouldProcess cmdlet' {
        $command = Get-Command Remove-AzFoundryDeployment
        $command.Parameters.Keys | Should -Contain 'WhatIf'
        $metadata = [System.Management.Automation.CommandMetadata]::new($command)
        $metadata.ConfirmImpact | Should -Be 'High'
    }

    It 'sends DELETE .../deployments/{name}' {
        Remove-AzFoundryDeployment @TestArmTarget -Name 'spike-embed' -Confirm:$false | Should -BeNullOrEmpty
        @(Get-TestArmCall DELETE).Uri | Should -Be @(
            "https://management.azure.com$TestAccountPath/deployments/spike-embed?api-version=2025-06-01")
    }

    It 'sends nothing with -WhatIf' {
        Remove-AzFoundryDeployment @TestArmTarget -Name 'spike-embed' -WhatIf
        Get-TestArmCall DELETE | Should -BeNullOrEmpty
    }

    It 'waits for an asynchronous deletion' {
        $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                Method = 'DELETE'; Pattern = '/deployments/'
                Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@(
                        (Get-TestFixtureResponse 'arm-deployment-delete-async')))
            })
        Add-TestArmRoute GET '/operationResults/' (New-TestResponse -Content (Get-TestFixture 'arm-operation-succeeded.json'))
        Remove-AzFoundryDeployment @TestArmTarget -Name 'spike-cohere' -Confirm:$false | Should -BeNullOrEmpty
        (Get-TestArmCall GET '/operationResults/').Count | Should -Be 1
    }

    It 'does not wait with -NoWait' {
        $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                Method = 'DELETE'; Pattern = '/deployments/'
                Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@(
                        (Get-TestFixtureResponse 'arm-deployment-delete-async')))
            })
        Remove-AzFoundryDeployment @TestArmTarget -Name 'spike-cohere' -NoWait -Confirm:$false
        Get-TestArmCall GET '/operationResults/' | Should -BeNullOrEmpty
    }

    It 'takes the deployments and their resource from Get-AzFoundryDeployment' {
        Get-AzFoundryDeployment @TestArmTarget | Remove-AzFoundryDeployment -Confirm:$false
        @(Get-TestArmCall DELETE).Uri | Should -Be @(
            "https://management.azure.com$TestAccountPath/deployments/Decision-1.1?api-version=2025-06-01"
            "https://management.azure.com$TestAccountPath/deployments/Mistral-Large-3?api-version=2025-06-01"
        )
    }

    It 'writes a non-terminating error for a failed item and goes on' {
        $global:AzFoundryTestArmRoutes.Insert(0, [pscustomobject]@{
                Method = 'DELETE'; Pattern = '/deployments/Decision-1\.1\?'
                Queue  = [System.Collections.Generic.Queue[object]]::new([object[]]@(
                        (New-TestResponse -StatusCode 409 -Content '{"error":{"code":"Conflict","message":"Busy."}}')))
            })
        $output = @(Get-AzFoundryDeployment @TestArmTarget | Remove-AzFoundryDeployment -Confirm:$false -ErrorAction Continue 2>&1)
        $output.Count | Should -Be 1
        $output[0] | Should -BeOfType [System.Management.Automation.ErrorRecord]
        $output[0].Exception.Message | Should -Match 'Busy'
        (Get-TestArmCall DELETE).Count | Should -Be 2
    }

    It 'needs a resource' {
        { Remove-AzFoundryDeployment -Name 'x' -Confirm:$false } |
            Should -Throw -ErrorId 'AzFoundryArmTargetMissing,Remove-AzFoundryDeployment'
    }
}
