#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Data-plane scenario on a real Foundry resource: connection (key, environment, Entra ID), chat, streaming,
    tool calling and decision. Uses the deployments that already exist on the resource (AZURE_FOUNDRY_CHAT_MODEL,
    AZURE_FOUNDRY_DECISION_MODEL) and creates nothing. Every request is small (a few hundred tokens in all).
#>

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'IntegrationHelpers.ps1')
    $setting = Get-ItSetting
    $skipEntra = -not ($setting.HasAzContext -and $setting.Endpoint)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'IntegrationHelpers.ps1')
    Import-ItModule
    $setting = Get-ItSetting
    $chatModel = $setting.ChatModel
    $decisionModel = $setting.DecisionModel

    $weather = New-AzFoundryTool -Name 'get_weather' -Description 'Current weather for a city' -Parameter @{
        type       = 'object'
        properties = @{ city = @{ type = 'string'; description = 'City name' } }
        required   = @('city')
    }
}

AfterAll {
    Disconnect-AzFoundry -ErrorAction SilentlyContinue
}

Describe 'Data plane with an API key' -Tag 'Integration' -Skip:(-not $setting.HasKey) {
    BeforeAll {
        Connect-AzFoundry -Endpoint $setting.Endpoint -ApiKey (Get-ItApiKey)
    }

    Context 'connection' {
        It 'shows the connection without the key' {
            $connection = Get-AzFoundryConnection
            $connection.AuthMode | Should -Be 'ApiKey'
            $connection.Source | Should -Be 'Session'
            $text = $connection | Format-List * | Out-String
            $text | Should -Not -Match ([regex]::Escape($env:AZURE_FOUNDRY_API_KEY))
        }

        It 'falls back to the environment variables when there is no session' {
            Disconnect-AzFoundry
            try {
                (Get-AzFoundryConnection).Source | Should -Be 'Environment'
                (Invoke-AzFoundryChat -Model $chatModel -Prompt 'Reply with OK.' -MaxTokens 5).Content |
                    Should -Not -BeNullOrEmpty
            } finally {
                Connect-AzFoundry -Endpoint $setting.Endpoint -ApiKey (Get-ItApiKey)
            }
        }

        It 'works with the other host form (<HostForm>)' -ForEach @(
            @{ HostForm = 'openai.azure.com' }
            @{ HostForm = 'services.ai.azure.com' }
        ) {
            $account = ([uri]$setting.Endpoint).Host.Split('.')[0]
            $result = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Reply with OK.' -MaxTokens 5 `
                -Endpoint "https://$account.$HostForm" -ApiKey (Get-ItApiKey)
            $result.Content | Should -Not -BeNullOrEmpty
        }
    }

    Context 'chat' {
        It 'answers a prompt with usage and rate limits' {
            $result = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Say hello in French, in two words.' -MaxTokens 20
            $result.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.ChatResult'
            $result.Content | Should -Not -BeNullOrEmpty
            $result.FinishReason | Should -BeIn 'stop', 'length'
            $result.Role | Should -Be 'assistant'
            $result.Usage.TotalTokens | Should -BeGreaterThan 0
            $result.RateLimit.RemainingRequests | Should -Not -BeNullOrEmpty
            $result.Created | Should -BeOfType [datetimeoffset]
        }

        It 'continues a conversation with ChatResult.Message' {
            $history = [System.Collections.Generic.List[object]]::new()
            $history.Add((New-AzFoundryMessage -Role user -Content 'My name is Ada. Reply with OK.'))
            $first = Invoke-AzFoundryChat -Model $chatModel -Message $history -MaxTokens 10
            $history.Add($first.Message)
            $history.Add((New-AzFoundryMessage -Role user -Content 'What is my name? One word.'))
            $second = Invoke-AzFoundryChat -Model $chatModel -Message $history -MaxTokens 10
            $second.Content | Should -Match 'Ada'
        }

        It 'returns the service JSON with -Raw' {
            $raw = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Reply with OK.' -MaxTokens 5 -Raw
            $raw.choices[0].message.content | Should -Not -BeNullOrEmpty
        }
    }

    Context 'streaming' {
        It 'writes chunks as they arrive and the aggregated result with -PassThru' {
            $output = @(Invoke-AzFoundryChat -Model $chatModel -Prompt 'Count from 1 to 10, comma separated.' `
                    -MaxTokens 60 -Stream -PassThru)
            $chunks = @($output | Where-Object { $_.PSObject.TypeNames[0] -eq 'PwshAzureFoundry.ChatChunk' })
            $result = $output[-1]
            $chunks.Count | Should -BeGreaterThan 1
            $result.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.ChatResult'
            $result.Content | Should -Be (-join $chunks.Content)
            $result.Usage.TotalTokens | Should -BeGreaterThan 0
        }

        It 'stops the stream with Select-Object -First and stays usable' {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $first = @(Invoke-AzFoundryChat -Model $chatModel -Prompt 'Write a 300-word story.' -MaxTokens 600 -Stream |
                    Select-Object -First 1)
            $stopwatch.Stop()
            $first.Count | Should -Be 1
            # The next call works: the cancelled stream released its connection.
            (Invoke-AzFoundryChat -Model $chatModel -Prompt 'Reply with OK.' -MaxTokens 5).Content |
                Should -Not -BeNullOrEmpty
            Write-Information ('First chunk after {0:N1} s.' -f $stopwatch.Elapsed.TotalSeconds) `
                -InformationAction Continue
        }
    }

    Context 'tool calling' {
        It 'returns the tool calls of the model (tool_choice required)' {
            $result = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Do I need an umbrella in Paris today?' `
                -Tool $weather -ToolChoice required -MaxTokens 200
            $result.FinishReason | Should -Be 'tool_calls'
            $result.ToolCalls.Count | Should -BeGreaterOrEqual 1
            $result.ToolCalls[0].Name | Should -Be 'get_weather'
            $result.ToolCalls[0].Id | Should -Not -BeNullOrEmpty
            $result.ToolCalls[0].Arguments['city'] | Should -Match 'Paris'
        }

        It 'forces one function with -ToolChoice <name>' {
            $result = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Is it raining in Lyon?' -Tool $weather `
                -ToolChoice get_weather -MaxTokens 200
            $result.ToolCalls[0].Name | Should -Be 'get_weather'
        }

        It 'answers in text after the tool results are sent back' {
            $history = [System.Collections.Generic.List[object]]::new()
            $history.Add((New-AzFoundryMessage -Role user -Content 'Do I need an umbrella in Paris today?'))
            $first = Invoke-AzFoundryChat -Model $chatModel -Message $history -Tool $weather -ToolChoice required `
                -MaxTokens 200
            $history.Add($first.Message)
            foreach ($call in $first.ToolCalls) {
                $history.Add((New-AzFoundryMessage -Role tool -ToolCallId $call.Id `
                            -Content @{ city = 'Paris'; forecast = 'rain'; tempC = 11 }))
            }
            $second = Invoke-AzFoundryChat -Model $chatModel -Message $history -Tool $weather -MaxTokens 100
            $second.FinishReason | Should -BeIn 'stop', 'length'
            $second.Content | Should -Not -BeNullOrEmpty
        }

        It 'aggregates streamed tool calls in the -PassThru result' {
            $result = Invoke-AzFoundryChat -Model $chatModel -Prompt 'Do I need an umbrella in Paris today?' `
                -Tool $weather -ToolChoice required -MaxTokens 200 -Stream -PassThru | Select-Object -Last 1
            $result.FinishReason | Should -Be 'tool_calls'
            $result.ToolCalls[0].Name | Should -Be 'get_weather'
            $result.ToolCalls[0].Arguments['city'] | Should -Match 'Paris'
        }
    }

    Context 'decision' {
        It 'answers the brief predicate' {
            $answer = Invoke-AzFoundryDecision -Model $decisionModel `
                -State 'The payment integration still fails. Please help today.' `
                -Predicate @{ urgent = 'Does this message convey urgency?' }
            $answer.PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.DecisionAnswer'
            $answer.Answer | Should -BeTrue
            $answer.Value | Should -BeGreaterThan 0.5
            $answer.InputTokens | Should -BeGreaterThan 0
        }

        It 'answers the three question types in order' {
            $ticket = @{
                subject = 'Charged twice'
                body    = 'My invoice is wrong, I was charged twice this month. Fix it now!'
            }
            $answers = @(Invoke-AzFoundryDecision -Model $decisionModel -State $ticket `
                    -Predicate @{ billing = 'Is this ticket about billing?' } `
                    -Choice @{ team = [ordered]@{ sales = 'Sales'; support = 'Support'; finance = 'Finance' } } `
                    -Score @{ priority = 'low', 'medium', 'high' })
            $answers.Question | Should -Be @('billing', 'team', 'priority')
            $answers[0].Answer | Should -BeTrue
            $answers[1].Answer | Should -BeIn 'sales', 'support', 'finance'
            @($answers[1].Probabilities.Keys) | Should -Be @('sales', 'support', 'finance')
            $answers[2].Answer | Should -BeIn 'low', 'medium', 'high'
        }

        It 'sends one request per piped state' {
            $answers = @('The server is down, customers cannot pay!', 'Can you send me the brochure?' |
                    Invoke-AzFoundryDecision -Model $decisionModel -Predicate @{ urgent = 'Is it urgent?' })
            $answers.Count | Should -Be 2
            $answers[0].State | Should -BeLike 'The server*'
        }

        It 'maps a service validation error' {
            { Invoke-AzFoundryDecision -Model $decisionModel -State 'x' -Question @{ q = @{ type = 'nope' } } } |
                Should -Throw -ErrorId '*,Invoke-AzFoundryDecision'
        }
    }

    Context 'errors' {
        It 'maps a missing deployment to ObjectNotFound with a hint' {
            $err = { Invoke-AzFoundryChat -Model 'pwshit-does-not-exist' -Prompt 'Hi' } | Should -Throw -PassThru
            $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
            $err.ErrorDetails.RecommendedAction | Should -Match 'Get-AzFoundryDeployment'
            $err.ToString() | Should -Not -Match ([regex]::Escape($env:AZURE_FOUNDRY_API_KEY))
        }

        It 'maps a wrong key to AuthenticationError' {
            $bad = [securestring]::new()
            foreach ($character in [char[]]('0' * 32)) { $bad.AppendChar($character) }
            $err = { Invoke-AzFoundryChat -Model $chatModel -Prompt 'Hi' -Endpoint $setting.Endpoint -ApiKey $bad } |
                Should -Throw -PassThru
            $err.CategoryInfo.Category | Should -Be 'AuthenticationError'
        }
    }
}

Describe 'Data plane with Entra ID' -Tag 'Integration' -Skip:$skipEntra {
    BeforeAll {
        Connect-AzFoundry -Endpoint $setting.Endpoint -UseEntraId
    }

    It 'chats with an Entra ID token' {
        (Get-AzFoundryConnection).AuthMode | Should -Be 'EntraId'
        (Invoke-AzFoundryChat -Model $chatModel -Prompt 'Reply with OK.' -MaxTokens 5).Content |
            Should -Not -BeNullOrEmpty
    }

    It 'calls the decision route with an Entra ID token' {
        $answer = Invoke-AzFoundryDecision -Model $decisionModel -State 'Please help today.' `
            -Predicate @{ urgent = 'Urgent?' }
        $answer.Type | Should -Be 'noul'
    }
}
