#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Import-AzFoundryAzAccounts' {
    BeforeEach {
        Mock -ModuleName PwshAzureFoundry Import-Module {}
    }

    It 'does nothing when a recent version is already loaded' {
        Mock -ModuleName PwshAzureFoundry Get-Module -ParameterFilter { -not $ListAvailable } {
            [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.5.0' }
        }
        InModuleScope PwshAzureFoundry { Import-AzFoundryAzAccounts }
        Should -Invoke Import-Module -ModuleName PwshAzureFoundry -Times 0 -Exactly
    }

    It 'fails when the loaded version is too old' {
        Mock -ModuleName PwshAzureFoundry Get-Module -ParameterFilter { -not $ListAvailable } {
            [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'1.7.3' }
        }
        $err = { InModuleScope PwshAzureFoundry { Import-AzFoundryAzAccounts } } |
            Should -Throw -ErrorId 'AzFoundryAzAccountsTooOld,Import-AzFoundryAzAccounts' -PassThru
        $err.CategoryInfo.Category | Should -Be 'NotInstalled'
    }

    It 'imports the newest suitable installed version globally' {
        Mock -ModuleName PwshAzureFoundry Get-Module -ParameterFilter { -not $ListAvailable } {}
        Mock -ModuleName PwshAzureFoundry Get-Module -ParameterFilter { $ListAvailable } {
            [pscustomobject]@{ Version = [version]'1.7.3'; Path = 'old/Az.Accounts.psd1' }
            [pscustomobject]@{ Version = [version]'5.5.3'; Path = 'new/Az.Accounts.psd1' }
            [pscustomobject]@{ Version = [version]'4.2.0'; Path = 'mid/Az.Accounts.psd1' }
        }
        InModuleScope PwshAzureFoundry { Import-AzFoundryAzAccounts }
        Should -Invoke Import-Module -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'new/Az.Accounts.psd1' -and $Global
        }
    }

    It 'fails with an install hint when Az.Accounts is not installed' {
        Mock -ModuleName PwshAzureFoundry Get-Module {}
        $err = { InModuleScope PwshAzureFoundry { Import-AzFoundryAzAccounts } } |
            Should -Throw -ErrorId 'AzFoundryAzAccountsNotInstalled,Import-AzFoundryAzAccounts' -PassThru
        $err.CategoryInfo.Category | Should -Be 'NotInstalled'
        $err.ErrorDetails.RecommendedAction | Should -Match 'Install-PSResource -Name Az.Accounts'
        $err.Exception.Message | Should -Match 'API key works without it'
    }
}
