#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'AzFoundryMessage' {
    It 'serialises a simple message as {role, content}' {
        InModuleScope PwshAzureFoundry {
            $json = [AzFoundryMessage]::new('user', 'I am going to Paris, what should I see?').ToHashtable() |
                ConvertTo-Json -Compress
            $json | Should -Be '{"role":"user","content":"I am going to Paris, what should I see?"}'
        }
    }

    It 'rejects an unknown role' {
        InModuleScope PwshAzureFoundry {
            { [AzFoundryMessage]::new('robot', 'hi') } | Should -Throw
        }
    }

    It 'adds name and tool_call_id only when set' {
        InModuleScope PwshAzureFoundry {
            $message = [AzFoundryMessage]::new('tool', '{"forecast":"rain"}')
            $message.ToolCallId = 'call_1'
            $hash = $message.ToHashtable()
            $hash.Keys | Should -Be @('role', 'content', 'tool_call_id')
            $hash.tool_call_id | Should -Be 'call_1'
        }
    }

    It 'serialises tool calls from ToolCall objects, with null content' {
        InModuleScope PwshAzureFoundry {
            $message = [AzFoundryMessage]::new('assistant', $null)
            $message.ToolCalls = @(
                [pscustomobject]@{ Id = 'call_1'; Name = 'get_weather'; ArgumentsJson = '{"city":"Paris"}' }
                [pscustomobject]@{ Id = 'call_2'; Name = 'get_time'; Arguments = @{ zone = 'CET' } }
                [pscustomobject]@{ Id = 'call_3'; Name = 'ping' }
            )
            $hash = $message.ToHashtable()

            $hash.Contains('content') | Should -BeTrue
            $hash.content | Should -BeNullOrEmpty
            $hash.tool_calls.Count | Should -Be 3
            $hash.tool_calls[0].type | Should -Be 'function'
            $hash.tool_calls[0].function.name | Should -Be 'get_weather'
            $hash.tool_calls[0].function.arguments | Should -Be '{"city":"Paris"}'
            $hash.tool_calls[1].function.arguments | Should -Be '{"zone":"CET"}'
            $hash.tool_calls[2].function.arguments | Should -Be '{}'

            ($hash | ConvertTo-Json -Depth 10 -Compress) | Should -Match '"content":null'
        }
    }

    It 'passes through tool calls already in the wire shape' {
        InModuleScope PwshAzureFoundry {
            $wire = @{ id = 'call_9'; type = 'function'; function = @{ name = 'f'; arguments = '{}' } }
            $message = [AzFoundryMessage]::new('assistant', 'Checking.')
            $message.ToolCalls = @($wire)
            $hash = $message.ToHashtable()
            $hash.content | Should -Be 'Checking.'
            $hash.tool_calls[0].id | Should -Be 'call_9'
        }
    }
}
