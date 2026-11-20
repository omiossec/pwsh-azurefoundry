#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:testKey = 'chat-SECRET-key-0123456789'
    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY
    $env:AZURE_FOUNDRY_ENDPOINT = $null
    $env:AZURE_FOUNDRY_API_KEY = $null

    $script:completion = Get-TestFixtureResponse 'chat-completion'
    $script:streamChunks = @(Get-TestStreamChunk 'chat-stream.txt')
    $script:toolStreamChunks = @(Get-TestStreamChunk 'synthetic-chat-toolcall-stream.txt')

    # The body of the last request, as canonical JSON.
    function Get-LastBody {
        ConvertTo-TestCanonicalJson $global:AzFoundryTestRequests[-1].Body
    }
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
    Remove-Variable -Name AzFoundryTestRequests -Scope Global -ErrorAction Ignore
    InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
}

Describe 'Invoke-AzFoundryChat' {
    BeforeEach {
        $global:AzFoundryTestRequests = [System.Collections.Generic.List[object]]::new()
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString $testKey)

        Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry {
            $global:AzFoundryTestRequests.Add([pscustomobject]@{
                    Connection = $Connection; Path = $Path; Body = $Body; TimeoutSec = $TimeoutSec
                })
            [pscustomobject]@{
                StatusCode = $completion.StatusCode
                Headers    = $completion.Headers
                Content    = $completion.Content | ConvertFrom-Json
            }
        }
        Mock Invoke-AzFoundryStreamRequest -ModuleName PwshAzureFoundry {
            $global:AzFoundryTestRequests.Add([pscustomobject]@{ Connection = $Connection; Path = $Path; Body = $Body })
            $ResponseHeaders['x-ratelimit-remaining-requests'] = '7'
            $streamChunks
        }
    }

    Context 'request body' {
        It 'matches the brief curl payload (snapshot)' {
            $history = @(
                New-AzFoundryMessage -Role user -Content 'I am going to Paris, what should I see?'
                New-AzFoundryMessage -Role assistant -Content ((Get-TestFixture 'chat-brief-request.json' |
                            ConvertFrom-Json).messages[1].content)
                New-AzFoundryMessage -Role user -Content 'What is so great about #1?'
            )
            $null = Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Message $history -MaxTokens 2048 -Temperature 0.8 -TopP 0.1

            Get-LastBody | Should -Be (ConvertTo-TestCanonicalJson (Get-TestFixture 'chat-brief-request.json'))
            $global:AzFoundryTestRequests[-1].Path | Should -Be '/openai/v1/chat/completions'
        }

        It 'sends only model and messages when no option is bound' {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi'
            $global:AzFoundryTestRequests[-1].Body.Keys | Should -Be @('model', 'messages')
            Get-LastBody | Should -Be '{"messages":[{"content":"hi","role":"user"}],"model":"m"}'
        }

        It 'maps -Stop, -Seed and -SystemPrompt' {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -SystemPrompt 'Be brief.' -Stop 'END' -Seed 42
            $body = $global:AzFoundryTestRequests[-1].Body
            $body.messages[0] | Should -Be $body.messages[0]
            (ConvertTo-Json $body.messages -Compress) | Should -Be '[{"role":"system","content":"Be brief."},{"role":"user","content":"hi"}]'
            (ConvertTo-Json -InputObject $body.stop -Compress) | Should -Be '["END"]'
            $body.seed | Should -Be 42
        }

        It 'maps -ResponseFormat <Case>' -ForEach @(
            @{ Case = 'text'; Value = 'text'; Expected = '{"type":"text"}' }
            @{ Case = 'json_object'; Value = 'json_object'; Expected = '{"type":"json_object"}' }
            @{ Case = 'with type'; Value = @{ type = 'json_object' }; Expected = '{"type":"json_object"}' }
            @{
                Case = 'schema'; Value = [ordered]@{ name = 'city'; schema = @{ type = 'object' } }
                Expected = '{"json_schema":{"name":"city","schema":{"type":"object"}},"type":"json_schema"}'
            }
        ) {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -ResponseFormat $Value
            ConvertTo-TestCanonicalJson $global:AzFoundryTestRequests[-1].Body.response_format | Should -Be $Expected
        }

        It 'rejects an unknown -ResponseFormat string' {
            { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -ResponseFormat 'xml' } |
                Should -Throw -ExpectedMessage "*must be 'text', 'json_object' or a hashtable*"
        }

        It 'rejects -Temperature out of 0-2' {
            { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Temperature 2.5 } |
                Should -Throw -ErrorId 'ParameterArgumentValidationError*'
        }

        It 'merges -ExtraBody last' {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -MaxTokens 5 -ExtraBody @{ max_tokens = 9; presence_penalty = 0.5 }
            $body = $global:AzFoundryTestRequests[-1].Body
            $body.max_tokens | Should -Be 9
            $body.presence_penalty | Should -Be 0.5
        }

        It 'accepts hashtable and object messages' {
            $messages = @(
                @{ role = 'system'; content = 'S' }
                [pscustomobject]@{ Role = 'user'; Content = 'U' }
            )
            $null = Invoke-AzFoundryChat -Model 'm' -Message $messages
            Get-LastBody | Should -Be '{"messages":[{"content":"S","role":"system"},{"content":"U","role":"user"}],"model":"m"}'
        }

        It 'rejects a message with no role' {
            { Invoke-AzFoundryChat -Model 'm' -Message 'just a string' } |
                Should -Throw -ErrorId 'AzFoundryInvalidMessage,Invoke-AzFoundryChat'
            { Invoke-AzFoundryChat -Model 'm' -Message @{ content = 'x' } } |
                Should -Throw -ErrorId 'AzFoundryInvalidMessage,Invoke-AzFoundryChat'
        }

        It 'passes -TimeoutSec to the request' {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -TimeoutSec 30
            $global:AzFoundryTestRequests[-1].TimeoutSec | Should -Be 30
        }
    }

    Context 'output' {
        It 'outputs a ChatResult with the rate limit' {
            $result = Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'ping'
            $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.ChatResult'
            $result.Content | Should -Be 'Pong'
            $result.RateLimit.RemainingRequests | Should -Be 19
        }

        It 'outputs the parsed response with -Raw' {
            $result = Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'ping' -Raw
            $result.PSTypeNames | Should -Not -Contain 'PwshAzureFoundry.ChatResult'
            $result.choices[0].message.content | Should -Be 'Pong'
        }

        It 'continues a conversation with ChatResult.Message' {
            $history = [System.Collections.Generic.List[object]]@(New-AzFoundryMessage -Role user -Content 'ping')
            $history.Add((Invoke-AzFoundryChat -Model 'm' -Message $history).Message)
            $history.Add((New-AzFoundryMessage -Role user -Content 'again'))
            $null = Invoke-AzFoundryChat -Model 'm' -Message $history
            (ConvertTo-Json $global:AzFoundryTestRequests[-1].Body.messages -Compress) |
                Should -Be '[{"role":"user","content":"ping"},{"role":"assistant","content":"Pong"},{"role":"user","content":"again"}]'
        }
    }

    Context 'pipeline' {
        It 'collects piped messages into one request' {
            $null = @(
                New-AzFoundryMessage -Role system -Content 'S'
                New-AzFoundryMessage -Role user -Content 'U'
            ) | Invoke-AzFoundryChat -Model 'm'
            $global:AzFoundryTestRequests.Count | Should -Be 1
            $global:AzFoundryTestRequests[0].Body.messages.Count | Should -Be 2
        }

        It 'binds -Model from the Name property of a Deployment object, one request per object' {
            $deployments = @(
                [pscustomobject]@{ PSTypeName = 'PwshAzureFoundry.Deployment'; Name = 'Mistral-Large-3' }
                [pscustomobject]@{ PSTypeName = 'PwshAzureFoundry.Deployment'; Name = 'gpt-4o-mini' }
            )
            $results = @($deployments | Invoke-AzFoundryChat -Prompt 'hi')
            $results.Count | Should -Be 2
            $global:AzFoundryTestRequests.Body.model | Should -Be @('Mistral-Large-3', 'gpt-4o-mini')
        }
    }

    Context 'tool calling' {
        BeforeAll {
            $script:weather = New-AzFoundryTool -Name 'get_weather' -Description 'Current weather' -Parameter @{
                type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city')
            }
        }

        It 'sends tools and tool_choice (snapshot)' {
            $raw = @{ type = 'function'; function = @{ name = 'get_time' } }
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Tool $weather, $raw -ToolChoice 'auto'
            $body = $global:AzFoundryTestRequests[-1].Body
            $body.tool_choice | Should -Be 'auto'
            ConvertTo-TestCanonicalJson $body.tools | Should -Be (
                '[{"function":{"description":"Current weather","name":"get_weather","parameters":{"properties":' +
                '{"city":{"type":"string"}},"required":["city"],"type":"object"}},"type":"function"},' +
                '{"function":{"name":"get_time"},"type":"function"}]')
        }

        It 'sends -ToolChoice <Choice> as <Expected>' -ForEach @(
            @{ Choice = 'none'; Expected = '"none"' }
            @{ Choice = 'required'; Expected = '"required"' }
            @{ Choice = 'get_weather'; Expected = '{"function":{"name":"get_weather"},"type":"function"}' }
        ) {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Tool $weather -ToolChoice $Choice
            $choiceJson = ConvertTo-Json -InputObject $global:AzFoundryTestRequests[-1].Body.tool_choice -Depth 5
            ConvertTo-TestCanonicalJson $choiceJson | Should -Be $Expected
        }

        It 'rejects an invalid tool' {
            { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Tool @{ name = 'x' } } |
                Should -Throw -ErrorId 'AzFoundryInvalidTool,Invoke-AzFoundryChat'
        }

        It 'round-trips the assistant tool calls and the tool answer into the next request' {
            Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry {
                $global:AzFoundryTestRequests.Add([pscustomobject]@{ Body = $Body })
                [pscustomobject]@{
                    StatusCode = 200; Headers = @{}
                    Content    = (Get-TestFixture 'synthetic-chat-toolcall.json') | ConvertFrom-Json
                }
            }
            $history = [System.Collections.Generic.List[object]]@(
                New-AzFoundryMessage -Role user -Content 'Umbrella in Paris?'
            )
            $result = Invoke-AzFoundryChat -Model 'm' -Message $history -Tool $weather
            $result.FinishReason | Should -Be 'tool_calls'

            $history.Add($result.Message)
            foreach ($call in $result.ToolCalls) {
                $answer = [ordered]@{ city = $call.Arguments['city']; forecast = 'rain' }
                $history.Add((New-AzFoundryMessage -Role tool -ToolCallId $call.Id -Content $answer))
            }
            $null = Invoke-AzFoundryChat -Model 'm' -Message $history -Tool $weather

            $messages = $global:AzFoundryTestRequests[-1].Body.messages
            $messages.Count | Should -Be 4
            (ConvertTo-Json $messages[1] -Depth 10 -Compress) | Should -Be ('{"role":"assistant","content":null,"tool_calls":[' +
                '{"id":"call_weather_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}},' +
                '{"id":"call_time_2","type":"function","function":{"name":"get_time","arguments":"{\"zone\":\"Europe/Paris\"}"}}]}')
            (ConvertTo-Json $messages[2] -Compress) |
                Should -Be '{"role":"tool","content":"{\"city\":\"Paris\",\"forecast\":\"rain\"}","tool_call_id":"call_weather_1"}'
            $messages[3].tool_call_id | Should -Be 'call_time_2'
        }
    }

    Context 'streaming' {
        It 'asks for a stream with usage and emits ChatChunk objects' {
            $chunks = @(Invoke-AzFoundryChat -Model 'm' -Prompt 'count' -Stream)
            $body = $global:AzFoundryTestRequests[-1].Body
            $body.stream | Should -BeTrue
            $body.stream_options.include_usage | Should -BeTrue

            $chunks.Count | Should -Be 11
            $chunks | ForEach-Object { $_.PSTypeNames | Should -Contain 'PwshAzureFoundry.ChatChunk' }
            (@($chunks.Content) -join '') | Should -Match '(?s)^Here is the count.*1 2 3 4 5 6 7 8 9 10$'
            $chunks[-1].FinishReason | Should -Be 'stop'
            Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 0
        }

        It 'adds the aggregated ChatResult with -PassThru' {
            $output = @(Invoke-AzFoundryChat -Model 'm' -Prompt 'count' -Stream -PassThru)
            $result = $output[-1]
            $result.PSTypeNames | Should -Contain 'PwshAzureFoundry.ChatResult'
            $result.Content | Should -Be (@($output[0..($output.Count - 2)].Content) -join '')
            $result.Usage.TotalTokens | Should -Be 53
            $result.RateLimit.RemainingRequests | Should -Be 7
        }

        It 'emits the raw chunks with -Stream -Raw' {
            $output = @(Invoke-AzFoundryChat -Model 'm' -Prompt 'count' -Stream -Raw)
            $output.Count | Should -Be 12
            $output[0].object | Should -Be 'chat.completion.chunk'
        }

        It 'aggregates streamed tool calls into the -PassThru result only' {
            Mock Invoke-AzFoundryStreamRequest -ModuleName PwshAzureFoundry { $toolStreamChunks }
            $output = @(Invoke-AzFoundryChat -Model 'm' -Prompt 'umbrella?' -Stream -PassThru -Tool $weather)
            $chunks = @($output | Where-Object { $_.PSTypeNames -contains 'PwshAzureFoundry.ChatChunk' })
            $chunks.Content | Where-Object { $_ } | Should -BeNullOrEmpty
            $output[-1].ToolCalls.Name | Should -Be @('get_weather', 'get_time')
            $output[-1].ToolCalls[0].Arguments.city | Should -Be 'Paris'
        }

        It 'stops reading when downstream stops the pipeline' {
            $first = @(Invoke-AzFoundryChat -Model 'm' -Prompt 'count' -Stream | Select-Object -First 2)
            $first.Count | Should -Be 2
        }

        It 'rejects -PassThru without -Stream' {
            { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -PassThru } |
                Should -Throw -ErrorId 'AzFoundryPassThruNeedsStream,Invoke-AzFoundryChat'
        }
    }

    Context 'connection and errors' {
        It 'fails when not connected' {
            InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
            { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' } |
                Should -Throw -ErrorId 'AzFoundryNotConnected,Invoke-AzFoundryChat'
        }

        It 'uses -Endpoint and -ApiKey over the session' {
            $null = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Endpoint 'https://other.openai.azure.com' `
                -ApiKey (New-TestSecureString 'other-key')
            $global:AzFoundryTestRequests[-1].Connection.Endpoint | Should -Be 'https://other.openai.azure.com'
            $global:AzFoundryTestRequests[-1].Connection.Source | Should -Be 'Parameter'
        }
    }
}

Describe 'Invoke-AzFoundryChat service errors (HTTP layer mocked)' {
    BeforeEach {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString $testKey)
    }

    It 'rethrows a 404 as ObjectNotFound with the public cmdlet name and no key in the message' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 404 -Content (Get-TestFixture 'error-deployment-not-found.json')
        }
        $err = { Invoke-AzFoundryChat -Model 'nope' -Prompt 'hi' } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike '*,Invoke-AzFoundryChat'
        $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
        $err.ErrorDetails.RecommendedAction | Should -Match 'Get-AzFoundryDeployment'
        $err.ToString() | Should -Not -Match ([regex]::Escape($testKey))
    }

    It 'rethrows a content filter error as SecurityError' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 400 -Content (Get-TestFixture 'synthetic-error-content-filter-400.json')
        }
        $err = { Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' } | Should -Throw -PassThru
        $err.CategoryInfo.Category | Should -Be 'SecurityError'
    }

    It 'sends the api-key header and never logs the key in -Debug or -Verbose output' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 200 -Content (Get-TestFixture 'chat-completion.json')
        }
        $output = Invoke-AzFoundryChat -Model 'm' -Prompt 'hi' -Verbose -Debug 4>&1 5>&1
        ($output | Out-String) | Should -Not -Match ([regex]::Escape($testKey))
        Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -ParameterFilter {
            $Headers['api-key'] -eq $testKey -and $Uri -eq 'https://lab.services.ai.azure.com/openai/v1/chat/completions'
        }
    }
}
