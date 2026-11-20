#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
}

Describe 'New-AzFoundryMessage' {
    It 'builds a <Role> message' -ForEach @(
        @{ Role = 'system' }, @{ Role = 'user' }, @{ Role = 'assistant' }
    ) {
        $message = New-AzFoundryMessage -Role $Role -Content 'Hello'
        $message.GetType().Name | Should -Be 'AzFoundryMessage'
        $message.Role | Should -Be $Role
        $message.Content | Should -Be 'Hello'
        ($message.ToHashtable() | ConvertTo-Json -Compress) | Should -Be "{`"role`":`"$Role`",`"content`":`"Hello`"}"
    }

    It 'takes Role and Content by position' {
        $message = New-AzFoundryMessage user 'Hi'
        $message.Role | Should -Be 'user'
        $message.Content | Should -Be 'Hi'
    }

    It 'builds one message per pipeline item' {
        $messages = @('one', 'two' | New-AzFoundryMessage -Role user)
        $messages.Count | Should -Be 2
        $messages[1].Content | Should -Be 'two'
    }

    It 'sets the participant name' {
        (New-AzFoundryMessage -Role user -Content 'x' -Name 'olivier_1').ToHashtable().name | Should -Be 'olivier_1'
    }

    It 'rejects an invalid name' {
        { New-AzFoundryMessage -Role user -Content 'x' -Name 'bad name' } |
            Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'rejects an unknown role' {
        { New-AzFoundryMessage -Role robot -Content 'x' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    Context 'tool messages' {
        It 'builds a tool message with tool_call_id' {
            $hash = (New-AzFoundryMessage -Role tool -ToolCallId 'call_1' -Content 'sunny').ToHashtable()
            $hash.Keys | Should -Be @('role', 'content', 'tool_call_id')
            $hash.tool_call_id | Should -Be 'call_1'
        }

        It 'converts a non-string content to compact JSON' {
            $content = [ordered]@{ city = 'Paris'; forecast = 'rain'; tempC = 11 }
            $message = New-AzFoundryMessage -Role tool -ToolCallId 'call_1' -Content $content
            $message.Content | Should -Be '{"city":"Paris","forecast":"rain","tempC":11}'
        }

        It 'fails when -ToolCallId is missing for a tool message' {
            { New-AzFoundryMessage -Role tool -Content 'x' } |
                Should -Throw -ErrorId 'AzFoundryToolCallIdMissing,New-AzFoundryMessage'
        }

        It 'fails when -ToolCallId is used with another role' {
            { New-AzFoundryMessage -Role user -Content 'x' -ToolCallId 'call_1' } |
                Should -Throw -ErrorId 'AzFoundryToolCallIdNotAllowed,New-AzFoundryMessage'
        }
    }

    It 'has a default table view with Role and Content' {
        $table = New-AzFoundryMessage -Role user -Content 'Hello there' | Out-String
        $table | Should -Match 'Role\s+Content'
        $table | Should -Match 'user\s+Hello there'
    }
}
