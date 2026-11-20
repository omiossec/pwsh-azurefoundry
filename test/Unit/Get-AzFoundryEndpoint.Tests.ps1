#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:accountJson = Get-TestFixture 'arm-account.json'
    $script:keysJson = '{"key1":"endpoint-SECRET-key-1","key2":"endpoint-SECRET-key-2"}'
}

AfterAll {
    Clear-TestArm
}

Describe 'Get-AzFoundryEndpoint' {
    BeforeEach {
        Initialize-TestArm
        Add-TestArmRoute GET '/accounts/test-foundry\?' (New-TestResponse -Content $accountJson)
        Add-TestArmRoute POST '/listKeys\?' (New-TestResponse -Content $keysJson)
    }

    It 'reads the account and derives the data-plane URIs' {
        $result = Get-AzFoundryEndpoint @TestArmTarget
        @(Get-TestArmCall).Uri | Should -Be @("https://management.azure.com${TestAccountPath}?api-version=2025-06-01")

        $result.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.Endpoint'
        $result.Endpoint | Should -Be 'https://test-foundry.services.ai.azure.com'
        $result.OpenAIEndpoint | Should -Be 'https://test-foundry.openai.azure.com'
        $result.ChatCompletionsUri | Should -Be 'https://test-foundry.services.ai.azure.com/openai/v1/chat/completions'
        $result.EmbeddingsUri | Should -Be 'https://test-foundry.services.ai.azure.com/openai/v1/embeddings'
        $result.DecisionUri | Should -Be 'https://test-foundry.services.ai.azure.com/providers/microsoft/v1/systemone'
        $result.Endpoints.Count | Should -Be 70
        $result.Endpoints['OpenAI Dall-E API'] | Should -Be 'https://test-foundry.openai.azure.com/'
        $result.Location | Should -Be 'swedencentral'
        $result.Kind | Should -Be 'AIServices'
        $result.AccountName | Should -Be 'test-foundry'
        $result.PSObject.Properties['Key1'] | Should -BeNullOrEmpty
    }

    It 'adds the keys as SecureString with -IncludeKey' {
        $result = Get-AzFoundryEndpoint @TestArmTarget -IncludeKey
        (Get-TestArmCall POST).Uri | Should -Be "https://management.azure.com$TestAccountPath/listKeys?api-version=2025-06-01"
        $result.Key1 | Should -BeOfType [securestring]
        $result.Key2 | Should -BeOfType [securestring]
        [System.Net.NetworkCredential]::new('', $result.Key1).Password | Should -Be 'endpoint-SECRET-key-1'
    }

    It 'never shows a key in the default, verbose or debug output' {
        $output = Get-AzFoundryEndpoint @TestArmTarget -IncludeKey -Verbose -Debug 4>&1 5>&1
        $text = ($output | Out-String) + ($output | Format-List * | Out-String)
        $text | Should -Not -Match 'endpoint-SECRET'
    }

    It 'warns when key authentication is disabled' {
        $json = $accountJson -replace '"disableLocalAuth":\s*false', '"disableLocalAuth": true'
        $global:AzFoundryTestArmRoutes[0].Queue.Clear()
        $global:AzFoundryTestArmRoutes[0].Queue.Enqueue((New-TestResponse -Content $json))
        $output = Get-AzFoundryEndpoint @TestArmTarget -IncludeKey 3>&1
        "$($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })" |
            Should -BeLike '*Key authentication is disabled*'
        ($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }).DisableLocalAuth |
            Should -BeTrue
    }

    It 'falls back to properties.endpoint when endpoints is missing' {
        $account = $accountJson | ConvertFrom-Json -Depth 50
        $account.properties.PSObject.Properties.Remove('endpoints')
        $account.properties.endpoint = 'https://test-foundry.cognitiveservices.azure.com/'
        $global:AzFoundryTestArmRoutes[0].Queue.Clear()
        $global:AzFoundryTestArmRoutes[0].Queue.Enqueue((New-TestResponse -Content ($account | ConvertTo-Json -Depth 50)))
        $result = Get-AzFoundryEndpoint @TestArmTarget
        $result.Endpoint | Should -Be 'https://test-foundry.cognitiveservices.azure.com'
        $result.OpenAIEndpoint | Should -Be 'https://test-foundry.openai.azure.com'
    }
}
