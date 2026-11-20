#Requires -Version 7.4

function New-AzFoundryTool {
    <#
    .SYNOPSIS
        Builds a function tool definition for Invoke-AzFoundryChat -Tool.
    .DESCRIPTION
        Creates an AzFoundryTool, sent to the model as {type:'function', function:{name, description,
        parameters}}. The model may then answer with tool calls (ChatResult.ToolCalls) instead of text.

        The module never runs your functions: your script reads the calls, runs its own code, answers each call
        with New-AzFoundryMessage -Role tool -ToolCallId, and calls Invoke-AzFoundryChat again.

        The cmdlet only builds an object in memory; it does not call the service.
    .PARAMETER Name
        Function name the model uses in its tool calls: letters, digits, '_' and '-', 64 characters at most.
    .PARAMETER Description
        What the function does and when to use it. The model reads it to decide whether to call the tool.
    .PARAMETER Parameter
        JSON Schema of the arguments, as a hashtable with type = 'object', properties and required. Leave it
        out for a function that takes no arguments.
    .EXAMPLE
        $weather = New-AzFoundryTool -Name 'get_weather' -Description 'Current weather for a city' -Parameter @{
            type       = 'object'
            properties = @{ city = @{ type = 'string'; description = 'City name' } }
            required   = @('city')
        }
        $result = Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Umbrella in Paris today?' -Tool $weather
        $result.ToolCalls

        Defines a tool and shows the calls the model asks for.
    .EXAMPLE
        New-AzFoundryTool -Name 'get_time' -Description 'Current UTC time'

        A tool with no arguments.
    .LINK
        Invoke-AzFoundryChat
    .LINK
        New-AzFoundryMessage
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory tool definition; changes no system state.'
    )]
    [CmdletBinding()]
    [OutputType('AzFoundryTool')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')]
        [string]$Name,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Description,

        [ValidateScript({ $_['type'] -eq 'object' },
            ErrorMessage = "-Parameter must be a JSON Schema object: @{{ type = 'object'; properties = @{{ ... }} }}.")]
        [System.Collections.IDictionary]$Parameter
    )

    [AzFoundryTool]::new($Name, $Description, $Parameter)
}
