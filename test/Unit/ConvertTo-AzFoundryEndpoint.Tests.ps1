#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'ConvertTo-AzFoundryEndpoint' {
    It 'normalises <Endpoint> to <Expected>' -ForEach @(
        @{ Endpoint = 'https://lab.services.ai.azure.com'; Expected = 'https://lab.services.ai.azure.com' }
        @{ Endpoint = 'https://lab.services.ai.azure.com/'; Expected = 'https://lab.services.ai.azure.com' }
        @{ Endpoint = 'https://LAB.openai.azure.com/openai/v1/'; Expected = 'https://lab.openai.azure.com' }
        @{ Endpoint = ' https://lab.services.ai.azure.com/models '; Expected = 'https://lab.services.ai.azure.com' }
        @{ Endpoint = 'https://ai.contoso.com:8443/x'; Expected = 'https://ai.contoso.com:8443' }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Endpoint = $Endpoint } {
            param($Endpoint)
            ConvertTo-AzFoundryEndpoint -Endpoint $Endpoint
        } | Should -Be $Expected
    }

    It 'switches to the <HostForm> host form' -ForEach @(
        @{ Endpoint = 'https://lab.openai.azure.com'; HostForm = 'Foundry'; Expected = 'https://lab.services.ai.azure.com' }
        @{ Endpoint = 'https://lab.services.ai.azure.com'; HostForm = 'OpenAI'; Expected = 'https://lab.openai.azure.com' }
        @{ Endpoint = 'https://ai.contoso.com'; HostForm = 'OpenAI'; Expected = 'https://ai.contoso.com' }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Endpoint = $Endpoint; HostForm = $HostForm } {
            param($Endpoint, $HostForm)
            ConvertTo-AzFoundryEndpoint -Endpoint $Endpoint -HostForm $HostForm
        } | Should -Be $Expected
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'http'; Endpoint = 'http://lab.services.ai.azure.com'; ErrorId = 'AzFoundryEndpointNotHttps' }
        @{ Case = 'a relative URI'; Endpoint = 'lab.services.ai.azure.com'; ErrorId = 'AzFoundryEndpointInvalid' }
        @{ Case = 'an empty string'; Endpoint = ''; ErrorId = 'AzFoundryEndpointInvalid' }
        @{ Case = 'a query string'; Endpoint = 'https://lab.openai.azure.com/?api-key=SECRETVALUE'; ErrorId = 'AzFoundryEndpointInvalid' }
        @{ Case = 'user info'; Endpoint = 'https://user:SECRETVALUE@lab.openai.azure.com'; ErrorId = 'AzFoundryEndpointInvalid' }
    ) {
        $err = {
            InModuleScope PwshAzureFoundry -Parameters @{ Endpoint = $Endpoint } {
                param($Endpoint)
                ConvertTo-AzFoundryEndpoint -Endpoint $Endpoint
            }
        } | Should -Throw -ErrorId "$ErrorId,ConvertTo-AzFoundryEndpoint" -PassThru
        $err.CategoryInfo.Category | Should -Be 'InvalidArgument'
        "$($err.Exception.Message) $($err.ErrorDetails.Message) $($err.TargetObject)" | Should -Not -Match 'SECRETVALUE'
    }
}
