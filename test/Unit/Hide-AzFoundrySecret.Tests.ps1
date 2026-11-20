#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'Hide-AzFoundrySecret' {
    It 'masks every occurrence of the given secrets' {
        InModuleScope PwshAzureFoundry {
            Hide-AzFoundrySecret -Text 'key k3y-VALUE and again k3y-VALUE' -Secret 'k3y-VALUE' |
                Should -Be 'key *** and again ***'
        }
    }

    It 'masks bearer tokens and api-key values even when not listed' {
        InModuleScope PwshAzureFoundry {
            $text = 'Authorization: Bearer eyJ0eXAiOiJKV1Qi.abc.def api-key: 0123456789abcdef "api-key":"fedcba9876543210"'
            $clean = Hide-AzFoundrySecret -Text $text
            $clean | Should -Not -Match 'eyJ0|0123456789abcdef|fedcba9876543210'
            $clean | Should -Match 'Bearer \*\*\*'
        }
    }

    It 'masks the keys of an ARM listKeys response' {
        InModuleScope PwshAzureFoundry {
            $clean = Hide-AzFoundrySecret -Text '{ "key1": "Abc/123+x=", "KEY2":"def-456" }'
            $clean | Should -Be '{ "key1": "***", "KEY2":"***" }'
        }
    }

    It 'returns null or empty text unchanged' {
        InModuleScope PwshAzureFoundry {
            Hide-AzFoundrySecret -Text '' -Secret 'x' | Should -BeExactly ''
            Hide-AzFoundrySecret -Text $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-AzFoundryLogUri' {
    It 'keeps only api-version from the query string' {
        InModuleScope PwshAzureFoundry {
            $uri = 'https://management.azure.com/subscriptions/x/operationResults/y?api-version=2025-06-01&t=1&s=SIG&h=H'
            ConvertTo-AzFoundryLogUri -Uri $uri |
                Should -Be 'https://management.azure.com/subscriptions/x/operationResults/y?api-version=2025-06-01&<redacted>'
        }
    }

    It 'leaves a URI without query unchanged' {
        InModuleScope PwshAzureFoundry {
            ConvertTo-AzFoundryLogUri -Uri 'https://lab.openai.azure.com/openai/v1/chat/completions' |
                Should -Be 'https://lab.openai.azure.com/openai/v1/chat/completions'
        }
    }

    It 'redacts a query without api-version' {
        InModuleScope PwshAzureFoundry {
            ConvertTo-AzFoundryLogUri -Uri 'https://host.example.com/p?sig=abc' |
                Should -Be 'https://host.example.com/p?<redacted>'
        }
    }
}

Describe 'New-AzFoundryErrorRecord' {
    It 'builds a record with category, target and recommended action' {
        InModuleScope PwshAzureFoundry {
            $record = New-AzFoundryErrorRecord -Message 'Boom.' -ErrorId 'TestId' -Category InvalidArgument `
                -TargetObject 'target' -ExceptionType ([System.ArgumentException]) -RecommendedAction 'Do this.'
            $record.Exception | Should -BeOfType [System.ArgumentException]
            $record.Exception.Message | Should -Be 'Boom.'
            $record.FullyQualifiedErrorId | Should -Be 'TestId'
            $record.CategoryInfo.Category | Should -Be 'InvalidArgument'
            $record.TargetObject | Should -Be 'target'
            $record.ErrorDetails.RecommendedAction | Should -Be 'Do this.'
        }
    }
}

Describe 'ConvertFrom-AzFoundryJsonContent' {
    It 'returns nothing for an empty body, an object for JSON and text otherwise' {
        InModuleScope PwshAzureFoundry {
            ConvertFrom-AzFoundryJsonContent -Content '' | Should -BeNullOrEmpty
            (ConvertFrom-AzFoundryJsonContent -Content '{"a":1}').a | Should -Be 1
            ConvertFrom-AzFoundryJsonContent -Content 'plain text' | Should -Be 'plain text'
        }
    }
}
