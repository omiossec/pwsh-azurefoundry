#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY
    $env:AZURE_FOUNDRY_ENDPOINT = $null
    $env:AZURE_FOUNDRY_API_KEY = $null

    $script:predicate = Get-TestFixtureResponse 'decision-predicate'
    $script:allTypes = Get-TestFixture 'decision-all-types.json'

    function Get-LastBody {
        ConvertTo-TestCanonicalJson $global:AzFoundryTestRequests[-1].Body
    }
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
    Remove-Variable -Name AzFoundryTestRequests, AzFoundryTestContent -Scope Global -ErrorAction Ignore
    InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
}

Describe 'Invoke-AzFoundryDecision' {
    BeforeEach {
        $global:AzFoundryTestRequests = [System.Collections.Generic.List[object]]::new()
        $global:AzFoundryTestContent = $predicate.Content
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'dec-key-0123')

        Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry {
            $global:AzFoundryTestRequests.Add([pscustomobject]@{ Path = $Path; Body = $Body; TimeoutSec = $TimeoutSec })
            [pscustomobject]@{
                StatusCode = 200
                Headers    = $predicate.Headers
                Content    = $global:AzFoundryTestContent | ConvertFrom-Json
            }
        }
    }

    Context 'request body' {
        It 'matches the brief curl payload (snapshot)' {
            $null = Invoke-AzFoundryDecision -Model 'Decision-1' `
                -State 'The payment integration still fails. Please help today.' `
                -Predicate @{ urgent = 'Does this message convey urgency?' }

            Get-LastBody | Should -Be (ConvertTo-TestCanonicalJson (Get-TestFixture 'decision-brief-request.json'))
            $global:AzFoundryTestRequests[-1].Path | Should -Be '/providers/microsoft/v1/systemone'
        }

        It 'builds the three question types like the spike request' {
            $global:AzFoundryTestContent = $allTypes
            $ticket = [ordered]@{
                subject = 'Charged twice'
                body    = 'My invoice is wrong, I was charged twice this month. Fix it now!'
            }
            $null = Invoke-AzFoundryDecision -Model 'Decision-1.1' -State $ticket `
                -Predicate @{ billing = 'Is this ticket about billing?' } `
                -Choice @{ team = [ordered]@{ sales = 'Sales'; support = 'Support'; finance = 'Finance' } } `
                -Score @{ priority = 'low', 'medium', 'high' }

            Get-LastBody | Should -Be (ConvertTo-TestCanonicalJson (Get-TestFixture 'decision-all-types-request.json'))
            $global:AzFoundryTestRequests[-1].Body.questions.Keys | Should -Be @('billing', 'team', 'priority')
        }

        It 'sends -Question definitions as-is, after the other types' {
            $raw = [ordered]@{ type = 'noul'; instructions = 'Is it spam?'; extra = 1 }
            $null = Invoke-AzFoundryDecision -Model 'd' -State 'x' -Question @{ spam = $raw } -Predicate @{ a = 'A?' }
            $questions = $global:AzFoundryTestRequests[-1].Body.questions
            $questions.Keys | Should -Be @('a', 'spam')
            $questions['spam'] | Should -Be $raw
        }

        It 'sends a piped string as a JSON string, one request per state' {
            $null = 'first', 'second' | Invoke-AzFoundryDecision -Model 'd' -Predicate @{ a = 'A?' }
            $global:AzFoundryTestRequests.Count | Should -Be 2
            (ConvertTo-Json -InputObject $global:AzFoundryTestRequests[0].Body.state -Compress) | Should -Be '"first"'
            $global:AzFoundryTestRequests[1].Body.state | Should -Be 'second'
        }

        It 'passes -TimeoutSec' {
            $null = Invoke-AzFoundryDecision -Model 'd' -State 'x' -Predicate @{ a = 'A?' } -TimeoutSec 7
            $global:AzFoundryTestRequests[-1].TimeoutSec | Should -Be 7
        }
    }

    Context 'output' {
        It 'returns one DecisionAnswer for the brief question' {
            $answer = Invoke-AzFoundryDecision -Model 'Decision-1.1' -State 'Please help today.' `
                -Predicate @{ urgent = 'Does this message convey urgency?' }

            $answer.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.DecisionAnswer'
            $answer.Question | Should -Be 'urgent'
            $answer.Answer | Should -BeTrue
            $answer.Value | Should -BeGreaterThan 0.99
            $answer.Model | Should -Be 'microsoft-decision-1.1'
            $answer.InputTokens | Should -Be 31
            $answer.State | Should -Be 'Please help today.'
            $answer.RateLimit.RemainingRequests | Should -Be 49
        }

        It 'returns the answers in the question order' {
            $global:AzFoundryTestContent = $allTypes
            $answers = Invoke-AzFoundryDecision -Model 'Decision-1.1' -State 'x' `
                -Predicate @{ billing = 'B?' } `
                -Choice @{ team = [ordered]@{ sales = 'Sales'; support = 'Support'; finance = 'Finance' } } `
                -Score @{ priority = 'low', 'medium', 'high' }
            $answers.Question | Should -Be @('billing', 'team', 'priority')
        }

        It 'applies -Threshold to predicates' {
            $answer = Invoke-AzFoundryDecision -Model 'd' -State 'x' -Predicate @{ urgent = 'U?' } -Threshold 0.999
            $answer.Answer | Should -BeFalse
            $answer.Confidence | Should -BeLessThan 0.01
        }

        It 'returns the service JSON with -Raw' {
            $raw = Invoke-AzFoundryDecision -Model 'd' -State 'x' -Predicate @{ urgent = 'U?' } -Raw
            $raw.PSObject.TypeNames[0] | Should -Not -Be 'PwshAzureFoundry.DecisionAnswer'
            $raw.answers.urgent.type | Should -Be 'noul'
            $raw.usage.input_tokens | Should -Be 31
        }
    }

    Context 'question errors' {
        It 'needs at least one question' {
            { Invoke-AzFoundryDecision -Model 'd' -State 'x' } |
                Should -Throw -ErrorId 'AzFoundryDecisionNoQuestion,Invoke-AzFoundryDecision'
            Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'a duplicate id'; Splat = @{ Predicate = @{ a = 'A?' }; Score = @{ a = 'low', 'high' } }
                Pattern = "*'a' is used more than once*" }
            @{ Case = 'empty instructions'; Splat = @{ Predicate = @{ a = ' ' } }; Pattern = '*non-empty instructions*' }
            @{ Case = 'a one-option choice'; Splat = @{ Choice = @{ c = @{ only = 'Only' } } }; Pattern = '*at least two option*' }
            @{ Case = 'a choice that is a list'; Splat = @{ Choice = @{ c = 'x', 'y' } }; Pattern = '*must be a dictionary*' }
            @{ Case = 'a one-level score'; Splat = @{ Score = @{ s = @('low') } }; Pattern = '*at least two levels*' }
            @{ Case = 'a raw question without type'; Splat = @{ Question = @{ q = @{ instructions = 'x' } } }
                Pattern = "*'type' entry*" }
        ) {
            $err = $null
            try {
                Invoke-AzFoundryDecision -Model 'd' -State 'x' @Splat
            } catch {
                $err = $_
            }
            $err.FullyQualifiedErrorId | Should -Be 'AzFoundryInvalidDecisionQuestion,Invoke-AzFoundryDecision'
            $err.CategoryInfo.Category | Should -Be 'InvalidArgument'
            $err.Exception.Message | Should -BeLike $Pattern
            Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }
    }

}

Describe 'Invoke-AzFoundryDecision over HTTP' {
    BeforeAll {
        $script:testKey = 'decision-SECRET-key-0123456789'
    }

    BeforeEach {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString $testKey)
    }

    It 'maps <Fixture> to <Category>' -ForEach @(
        @{ Fixture = 'error-decision-deployment-not-found.json'; Status = 404; Category = 'ObjectNotFound' }
        @{ Fixture = 'error-decision-validation-422.json'; Status = 422; Category = 'InvalidArgument' }
    ) {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode $Status -Content (Get-TestFixture $Fixture)
        }
        $err = { Invoke-AzFoundryDecision -Model 'Decision-1' -State 'x' -Predicate @{ a = 'A?' } } |
            Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike '*,Invoke-AzFoundryDecision'
        $err.CategoryInfo.Category | Should -Be $Category
        $err.ToString() | Should -Not -Match ([regex]::Escape($testKey))
    }

    It 'calls the systemone route and never logs the key in -Debug or -Verbose output' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 200 -Content (Get-TestFixture 'decision-predicate.json')
        }
        $output = Invoke-AzFoundryDecision -Model 'd' -State 'x' -Predicate @{ a = 'A?' } -Verbose -Debug 4>&1 5>&1
        ($output | Out-String) | Should -Not -Match ([regex]::Escape($testKey))
        Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -ParameterFilter {
            $Uri -eq 'https://lab.services.ai.azure.com/providers/microsoft/v1/systemone'
        }
    }
}

Describe 'ConvertTo-AzFoundryDecision' {
    It 'maps the three answer types from the fixture' {
        InModuleScope PwshAzureFoundry -Parameters @{ Json = (Get-TestFixture 'decision-all-types.json') } {
            param($Json)
            $questions = [ordered]@{
                billing  = [ordered]@{ type = 'noul'; instructions = 'B?' }
                team     = [ordered]@{ type = 'choice'; criteria = [ordered]@{ sales = 'S'; support = 'Su'; finance = 'F' } }
                priority = [ordered]@{ type = 'score'; criteria = @('low', 'medium', 'high') }
            }
            $answers = @(ConvertTo-AzFoundryDecision -Response ($Json | ConvertFrom-Json) -Questions $questions)
            $answers.Count | Should -Be 3

            $billing, $team, $priority = $answers
            $billing.Type | Should -Be 'noul'
            $billing.Answer | Should -BeTrue
            $billing.Value | Should -Be 0.9969547856479505
            $billing.Confidence | Should -Be 0.9969547856479505
            $billing.Probabilities | Should -BeNullOrEmpty

            $team.Type | Should -Be 'choice'
            $team.Answer | Should -Be 'finance'
            $team.Value | Should -BeNullOrEmpty
            $team.Confidence | Should -Be 0.9002991318726765
            @($team.Probabilities.Keys) | Should -Be @('sales', 'support', 'finance')
            $team.Probabilities['finance'] | Should -Be 0.9335327545817843

            $priority.Type | Should -Be 'score'
            $priority.Answer | Should -Be 'high'
            $priority.Value | Should -Be 1.3908978752562593
            $priority.Confidence | Should -Be 0.28097948968404396
            @($priority.Probabilities.Keys) | Should -Be @('low', 'medium', 'high')
            $priority.Probabilities['medium'] | Should -Be 0.34959188901086746

            $answers.InputTokens | Should -Be @(91, 91, 91)
            $answers.OutputTokens | Should -Be @(3, 3, 3)
            $answers.Model | Select-Object -Unique | Should -Be 'microsoft-decision-1.1'
        }
    }

    It 'gives a false predicate the confidence 1 - p' {
        InModuleScope PwshAzureFoundry {
            $response = '{"model":"m","answers":{"q":{"type":"noul","noul":0.2}}}' | ConvertFrom-Json
            $answer = ConvertTo-AzFoundryDecision -Response $response
            $answer.Answer | Should -BeFalse
            $answer.Confidence | Should -Be 0.8
            $answer.InputTokens | Should -BeNullOrEmpty
            $answer.RateLimit | Should -BeNullOrEmpty
        }
    }

    It 'uses the level index as label when there is no legend' {
        InModuleScope PwshAzureFoundry {
            $response = '{"answers":{"s":{"type":"score","score":0.4,"probabilities":{"1":0.3,"0":0.7}}}}' |
                ConvertFrom-Json
            $answer = ConvertTo-AzFoundryDecision -Response $response
            @($answer.Probabilities.Keys) | Should -Be @('0', '1')
            $answer.Answer | Should -Be '0'
        }
    }

    It 'warns on an unknown answer type and still outputs it' {
        InModuleScope PwshAzureFoundry {
            $response = '{"answers":{"x":{"type":"future","foo":1}}}' | ConvertFrom-Json
            $output = ConvertTo-AzFoundryDecision -Response $response 3>&1
            $warning = $output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $answer = $output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            "$warning" | Should -BeLike "*unknown type 'future'*"
            $answer.Type | Should -Be 'future'
            $answer.Answer | Should -BeNullOrEmpty
        }
    }

    It 'outputs nothing when there is no answers object' {
        InModuleScope PwshAzureFoundry {
            ConvertTo-AzFoundryDecision -Response ([pscustomobject]@{ answers = $null }) | Should -BeNullOrEmpty
        }
    }
}
