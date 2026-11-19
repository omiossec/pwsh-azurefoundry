#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    function Get-TestDelay {
        param([hashtable]$Headers, [int]$Attempt = 1, [hashtable]$Extra = @{})
        InModuleScope PwshAzureFoundry -Parameters @{ H = $Headers; A = $Attempt; E = $Extra } {
            param($H, $A, $E)
            Get-AzFoundryRetryDelay -Headers $H -Attempt $A @E
        }
    }
}

Describe 'Get-AzFoundryRetryDelay' {
    It 'honours Retry-After in seconds' {
        Get-TestDelay -Headers @{ 'Retry-After' = '6' } | Should -Be 6
    }

    It 'prefers retry-after-ms' {
        Get-TestDelay -Headers @{ 'Retry-After' = '6'; 'retry-after-ms' = '1500' } | Should -Be 1.5
    }

    It 'honours x-ms-retry-after-ms' {
        Get-TestDelay -Headers @{ 'x-ms-retry-after-ms' = '250' } | Should -Be 0.25
    }

    It 'honours Retry-After as an HTTP date' {
        $date = [datetimeoffset]::UtcNow.AddSeconds(10).ToString('r')
        $delay = Get-TestDelay -Headers @{ 'Retry-After' = $date }
        $delay | Should -BeGreaterThan 7
        $delay | Should -BeLessOrEqual 10
    }

    It 'treats a past HTTP date as no wait' {
        Get-TestDelay -Headers @{ 'Retry-After' = 'Mon, 01 Jan 2024 00:00:00 GMT' } | Should -Be 0
    }

    It 'backs off exponentially without a header (attempt <Attempt>)' -ForEach @(
        @{ Attempt = 1; Low = 1; High = 2 }
        @{ Attempt = 2; Low = 2; High = 3 }
        @{ Attempt = 3; Low = 4; High = 5 }
    ) {
        $delay = Get-TestDelay -Headers @{} -Attempt $Attempt
        $delay | Should -BeGreaterOrEqual $Low
        $delay | Should -BeLessOrEqual $High
    }

    It 'uses -DefaultSeconds instead of backoff when given' {
        Get-TestDelay -Headers @{} -Attempt 4 -Extra @{ DefaultSeconds = 5 } | Should -Be 5
    }

    It 'caps the delay at -MaximumSeconds' {
        Get-TestDelay -Headers @{ 'Retry-After' = '3600' } -Extra @{ MaximumSeconds = 60 } | Should -Be 60
    }

    It 'ignores invalid header values' {
        Get-TestDelay -Headers @{ 'Retry-After' = 'soon' } -Extra @{ DefaultSeconds = 2 } | Should -Be 2
    }
}
