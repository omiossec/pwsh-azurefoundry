#Requires -Version 7.4

function ConvertTo-AzFoundryToolCall {
    <#
    .SYNOPSIS
        Converts the tool_calls of a chat completion message to PwshAzureFoundry.ToolCall objects.
    .DESCRIPTION
        One object per call: Id, Name, Arguments (hashtable parsed with ConvertFrom-Json -AsHashtable) and
        ArgumentsJson (the raw string, always kept). When the model returns arguments that are not valid JSON,
        Arguments is $null and a warning is written. Empty arguments give an empty hashtable.
    .PARAMETER ToolCall
        The tool_calls array of the response message (items { id, type, function = { name, arguments } }).
    .EXAMPLE
        ConvertTo-AzFoundryToolCall -ToolCall $response.choices[0].message.tool_calls
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.ToolCall')]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ToolCall
    )

    foreach ($call in $ToolCall) {
        if ($null -eq $call) {
            continue
        }
        $function = $call.function
        $name = [string]$function.name
        $json = [string]$function.arguments

        $arguments = $null
        if ([string]::IsNullOrWhiteSpace($json)) {
            $arguments = @{}
        } else {
            try {
                $arguments = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 100 -ErrorAction Stop
            } catch {
                $text = "The arguments of tool call '{0}' ({1}) are not valid JSON; Arguments is empty and " +
                'ArgumentsJson keeps the text.'
                Write-Warning ($text -f $call.id, $name)
            }
        }

        [pscustomobject]@{
            PSTypeName    = 'PwshAzureFoundry.ToolCall'
            Id            = [string]$call.id
            Name          = $name
            Arguments     = $arguments
            ArgumentsJson = $json
        }
    }
}
