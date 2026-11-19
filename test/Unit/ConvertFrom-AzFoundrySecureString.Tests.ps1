#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'ConvertFrom-AzFoundrySecureString / ConvertTo-AzFoundrySecureString' {
    It 'round-trips a secret' {
        InModuleScope PwshAzureFoundry {
            $secure = ConvertTo-AzFoundrySecureString -String 'abc123-key'
            $secure | Should -BeOfType [securestring]
            $secure.IsReadOnly() | Should -BeTrue
            ConvertFrom-AzFoundrySecureString -SecureString $secure | Should -BeExactly 'abc123-key'
        }
    }

    It 'handles an empty string' {
        InModuleScope PwshAzureFoundry {
            $secure = ConvertTo-AzFoundrySecureString -String ''
            $secure.Length | Should -Be 0
            ConvertFrom-AzFoundrySecureString -SecureString $secure | Should -BeExactly ''
        }
    }
}
