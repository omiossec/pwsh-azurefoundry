#Requires -Version 7.4

function ConvertTo-AzFoundryRequestMessage {
    <#
    .SYNOPSIS
        Converts the -Message input of Invoke-AzFoundryChat to the wire shape of the chat completions API.
    .DESCRIPTION
        Accepts, for each item:

          AzFoundryMessage     ToHashtable() (New-AzFoundryMessage, ChatResult.Message)
          IDictionary          sent as-is; it must have a 'role' key (wire shape: role, content, tool_calls...)
          other objects        their Role, Content, Name, ToolCallId and ToolCalls properties
                               (for example a message read back from JSON)

        Anything else, or an item with no role, is a terminating error (AzFoundryInvalidMessage).
    .PARAMETER InputObject
        The messages.
    .EXAMPLE
        $messages = @(ConvertTo-AzFoundryRequestMessage -InputObject $Message)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    foreach ($item in $InputObject) {
        $value = if ($item -is [psobject]) { $item.PSObject.BaseObject } else { $item }

        if ($value -is [AzFoundryMessage]) {
            $value.ToHashtable()
            continue
        }

        if ($value -is [System.Collections.IDictionary]) {
            if ($value.Contains('role') -and -not [string]::IsNullOrWhiteSpace([string]$value['role'])) {
                $value
                continue
            }
        } elseif ($null -ne $value -and $value -isnot [string] -and $value -isnot [ValueType] -and
            $item.PSObject.Properties['Role'] -and -not [string]::IsNullOrWhiteSpace([string]$item.Role)) {
            try {
                $message = [AzFoundryMessage]::new()
                $message.Role = [string]$item.Role
                foreach ($name in 'Content', 'Name', 'ToolCallId', 'ToolCalls') {
                    if ($item.PSObject.Properties[$name] -and $null -ne $item.$name) {
                        $message.$name = $item.$name
                    }
                }
                $message.ToHashtable()
                continue
            } catch {
                Write-Debug "Message conversion failed: $($_.Exception.Message)"
            }
        }

        $shown = if ($null -eq $value) { '$null' } else { $value.GetType().Name }
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Invalid chat message ($shown): a message needs a role (system, user, assistant, tool)." `
                    -ErrorId 'AzFoundryInvalidMessage' -Category InvalidArgument -TargetObject $shown `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction 'Use New-AzFoundryMessage, or @{ role = ...; content = ... }.'))
    }
}
