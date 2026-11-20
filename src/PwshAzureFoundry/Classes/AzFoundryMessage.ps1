#Requires -Version 7.4

# One chat message (spec section 6). ToHashtable() returns the wire shape of the chat completions API.
class AzFoundryMessage {
    [ValidateSet('system', 'user', 'assistant', 'tool')]
    [string] $Role

    # May be empty for an assistant message that only carries tool calls.
    [string] $Content

    [string] $Name

    # Id of the tool call this message answers (role 'tool').
    [string] $ToolCallId

    # Tool calls requested by the model (role 'assistant'). Each item is either a
    # PwshAzureFoundry.ToolCall object (Id, Name, Arguments, ArgumentsJson) or a hashtable already in
    # the wire shape { id, type, function = { name, arguments } }.
    [object[]] $ToolCalls

    AzFoundryMessage() {}

    AzFoundryMessage([string]$role, [string]$content) {
        $this.Role    = $role
        $this.Content = $content
    }

    [System.Collections.Specialized.OrderedDictionary] ToHashtable() {
        $message = [ordered]@{ role = $this.Role }

        $hasToolCalls = $null -ne $this.ToolCalls -and $this.ToolCalls.Count -gt 0
        if ($hasToolCalls -and [string]::IsNullOrEmpty($this.Content)) {
            $message['content'] = $null
        } else {
            $message['content'] = [string]$this.Content
        }

        if (-not [string]::IsNullOrEmpty($this.Name)) {
            $message['name'] = $this.Name
        }
        if (-not [string]::IsNullOrEmpty($this.ToolCallId)) {
            $message['tool_call_id'] = $this.ToolCallId
        }
        if ($hasToolCalls) {
            $message['tool_calls'] = @(
                foreach ($call in $this.ToolCalls) {
                    [AzFoundryMessage]::ConvertToolCall($call)
                }
            )
        }
        return $message
    }

    hidden static [System.Collections.IDictionary] ConvertToolCall([object]$call) {
        if ($call -is [System.Collections.IDictionary] -and $call.Contains('function')) {
            return $call
        }

        $arguments = $call.ArgumentsJson
        if ([string]::IsNullOrEmpty($arguments)) {
            $arguments = if ($null -eq $call.Arguments) {
                '{}'
            } else {
                ConvertTo-Json -InputObject $call.Arguments -Depth 20 -Compress
            }
        }

        return [ordered]@{
            id       = [string]$call.Id
            type     = 'function'
            function = [ordered]@{
                name      = [string]$call.Name
                arguments = [string]$arguments
            }
        }
    }

    [string] ToString() {
        return '{0}: {1}' -f $this.Role, $this.Content
    }
}
