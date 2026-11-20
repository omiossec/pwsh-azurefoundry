#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'ConvertTo-AzFoundryChatResult' {
    It 'maps chat-completion.json and its rate-limit headers' {
        $fixture = Get-TestFixtureResponse 'chat-completion'
        InModuleScope PwshAzureFoundry -Parameters @{ Fixture = $fixture } {
            param($Fixture)
            $result = ConvertTo-AzFoundryChatResult -Response ($Fixture.Content | ConvertFrom-Json) -Headers $Fixture.Headers

            $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.ChatResult'
            $result.Content | Should -Be 'Pong'
            $result.Role | Should -Be 'assistant'
            $result.FinishReason | Should -Be 'stop'
            $result.Model | Should -Be 'mistral-large-3'
            $result.Id | Should -Be 'b6001e9358d14846af5e2fb4c22666c8'
            $result.Created | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds(1794952293))
            $result.Usage.PromptTokens | Should -Be 11
            $result.Usage.CompletionTokens | Should -Be 3
            $result.Usage.TotalTokens | Should -Be 14
            @($result.ToolCalls).Count | Should -Be 0
            $result.RateLimit.RemainingRequests | Should -Be 19
            $result.RateLimit.RemainingTokens | Should -Be 19971
            $result.RateLimit.LimitRequests | Should -Be 20
            $result.RateLimit.LimitTokens | Should -Be 20000
            $result.Raw.object | Should -Be 'chat.completion'

            $result.Message.GetType().Name | Should -Be 'AzFoundryMessage'
            ($result.Message.ToHashtable() | ConvertTo-Json -Compress) | Should -Be '{"role":"assistant","content":"Pong"}'
        }
    }

    It 'joins content parts and defaults the role to assistant' {
        InModuleScope PwshAzureFoundry {
            $response = '{"choices":[{"index":0,"message":{"content":[{"type":"text","text":"Hel"},' +
            '{"type":"text","text":"lo"}]},"finish_reason":"stop"}]}' | ConvertFrom-Json
            $result = ConvertTo-AzFoundryChatResult -Response $response
            $result.Content | Should -Be 'Hello'
            $result.Role | Should -Be 'assistant'
            $result.Usage | Should -BeNullOrEmpty
        }
    }

    It 'has no RateLimit when there is no rate-limit header' {
        InModuleScope PwshAzureFoundry {
            $response = Get-Content -Raw "$PSScriptRoot/../Fixtures/chat-tiny.json" | ConvertFrom-Json
            (ConvertTo-AzFoundryChatResult -Response $response -Headers @{}).RateLimit | Should -BeNullOrEmpty
        }
    }

    It 'shows FinishReason, Tokens and Content in the default view' {
        InModuleScope PwshAzureFoundry {
            $response = Get-Content -Raw "$PSScriptRoot/../Fixtures/chat-completion.json" | ConvertFrom-Json
            $table = ConvertTo-AzFoundryChatResult -Response $response | Out-String -Width 100
            $table | Should -Match 'FinishReason\s+Tokens\s+Content'
            $table | Should -Match 'stop\s+14\s+Pong'
        }
    }

    Context 'tool calls' {
        BeforeAll {
            $script:toolResponse = Get-TestFixture 'synthetic-chat-toolcall.json'
        }

        It 'maps the tool calls (Id, Name, Arguments, ArgumentsJson)' {
            InModuleScope PwshAzureFoundry -Parameters @{ Json = $toolResponse } {
                param($Json)
                $result = ConvertTo-AzFoundryChatResult -Response ($Json | ConvertFrom-Json)

                $result.FinishReason | Should -Be 'tool_calls'
                $result.Content | Should -BeNullOrEmpty
                $result.ToolCalls.Count | Should -Be 2
                $result.ToolCalls[0].PSTypeNames | Should -Contain 'PwshAzureFoundry.ToolCall'
                $result.ToolCalls[0].Id | Should -Be 'call_weather_1'
                $result.ToolCalls[0].Name | Should -Be 'get_weather'
                $result.ToolCalls[0].Arguments.city | Should -Be 'Paris'
                $result.ToolCalls[0].ArgumentsJson | Should -Be '{"city":"Paris"}'
                $result.ToolCalls[1].Arguments.zone | Should -Be 'Europe/Paris'
            }
        }

        It 'keeps the tool calls in Message, with null content, for the next request' {
            InModuleScope PwshAzureFoundry -Parameters @{ Json = $toolResponse } {
                param($Json)
                $result = ConvertTo-AzFoundryChatResult -Response ($Json | ConvertFrom-Json)
                $wire = $result.Message.ToHashtable() | ConvertTo-Json -Depth 10 -Compress
                $wire | Should -Be ('{"role":"assistant","content":null,"tool_calls":[' +
                    '{"id":"call_weather_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},' +
                    '{"id":"call_time_2","type":"function","function":{"name":"get_time","arguments":"{\"zone\":\"Europe/Paris\"}"}}]}')
            }
        }

        It 'writes a warning and keeps ArgumentsJson when the arguments are not valid JSON' {
            InModuleScope PwshAzureFoundry {
                $response = [pscustomobject]@{
                    choices = @([pscustomobject]@{
                            index         = 0
                            finish_reason = 'tool_calls'
                            message       = [pscustomobject]@{
                                role       = 'assistant'
                                content    = $null
                                tool_calls = @([pscustomobject]@{
                                        id = 'call_1'; type = 'function'
                                        function = [pscustomobject]@{ name = 'get_weather'; arguments = '{"city": Par' }
                                    })
                            }
                        })
                }
                $result = ConvertTo-AzFoundryChatResult -Response $response -WarningVariable warnings -WarningAction SilentlyContinue
                $warnings.Count | Should -Be 1
                $warnings[0].Message | Should -Match "call_1.*not valid JSON"
                $result.ToolCalls[0].Arguments | Should -BeNullOrEmpty
                $result.ToolCalls[0].ArgumentsJson | Should -Be '{"city": Par'
                $result.Message.ToHashtable().tool_calls[0].function.arguments | Should -Be '{"city": Par'
            }
        }

        It 'gives an empty hashtable for empty arguments' {
            InModuleScope PwshAzureFoundry {
                $calls = @(ConvertTo-AzFoundryToolCall -ToolCall @(
                        [pscustomobject]@{ id = 'c'; function = [pscustomobject]@{ name = 'get_time'; arguments = '' } }))
                $calls[0].Arguments | Should -BeOfType [hashtable]
                $calls[0].Arguments.Count | Should -Be 0
            }
        }

        It 'shows the tool call names in the ChatResult view and Id, Name, ArgumentsJson in the ToolCall view' {
            InModuleScope PwshAzureFoundry -Parameters @{ Json = $toolResponse } {
                param($Json)
                $result = ConvertTo-AzFoundryChatResult -Response ($Json | ConvertFrom-Json)
                ($result | Out-String -Width 120) | Should -Match '\[tool calls: get_weather, get_time\]'
                $table = $result.ToolCalls | Out-String -Width 120
                $table | Should -Match 'Id\s+Name\s+ArgumentsJson'
                $table | Should -Match 'call_weather_1\s+get_weather\s+\{"city":"Paris"\}'
            }
        }
    }
}

Describe 'AzFoundryChatStream' {
    It 'aggregates chat-stream.txt: content, finish reason, usage' {
        $chunks = @(Get-TestStreamChunk 'chat-stream.txt')
        InModuleScope PwshAzureFoundry -Parameters @{ Chunks = $chunks } {
            param($Chunks)
            $stream = [AzFoundryChatStream]::new()
            $emitted = foreach ($chunk in $Chunks) { $stream.Add($chunk) }

            # The first chunk (role only, empty content) is not emitted.
            @($emitted).Count | Should -Be 11
            $emitted[0].PSTypeNames | Should -Contain 'PwshAzureFoundry.ChatChunk'
            $emitted[0].Content | Should -Be 'Here'
            $emitted[-1].FinishReason | Should -Be 'stop'
            (@($emitted.Content) -join '') | Should -Be "Here is the count from 1 to 10, separated by spaces:`n`n1 2 3 4 5 6 7 8 9 10"

            $result = ConvertTo-AzFoundryChatResult -Response $stream.ToCompletion()
            $result.Content | Should -Be (@($emitted.Content) -join '')
            $result.FinishReason | Should -Be 'stop'
            $result.Usage.TotalTokens | Should -Be 53
            $result.Model | Should -Be 'mistral-large-3'
            $result.Id | Should -Be '69430cefaaf647cb9406350656234dc4'
        }
    }

    It 'aggregates streamed tool calls: split arguments, two parallel calls, nothing emitted' {
        $chunks = @(Get-TestStreamChunk 'synthetic-chat-toolcall-stream.txt')
        InModuleScope PwshAzureFoundry -Parameters @{ Chunks = $chunks } {
            param($Chunks)
            $stream = [AzFoundryChatStream]::new()
            $emitted = @(foreach ($chunk in $Chunks) { $stream.Add($chunk) })

            # Only the last chunk is emitted, for its finish reason; it has no content.
            $emitted.Count | Should -Be 1
            $emitted[0].FinishReason | Should -Be 'tool_calls'
            $emitted[0].Content | Should -BeNullOrEmpty

            $result = ConvertTo-AzFoundryChatResult -Response $stream.ToCompletion()
            $result.FinishReason | Should -Be 'tool_calls'
            $result.Content | Should -BeNullOrEmpty
            $result.ToolCalls.Count | Should -Be 2
            $result.ToolCalls[0].Id | Should -Be 'call_weather_1'
            $result.ToolCalls[0].Name | Should -Be 'get_weather'
            $result.ToolCalls[0].ArgumentsJson | Should -Be '{"city":"Paris"}'
            $result.ToolCalls[1].Id | Should -Be 'call_time_2'
            $result.ToolCalls[1].Arguments.zone | Should -Be 'Europe/Paris'
            $result.Usage.TotalTokens | Should -Be 119
            $result.Message.ToHashtable().content | Should -BeNullOrEmpty
        }
    }
}
