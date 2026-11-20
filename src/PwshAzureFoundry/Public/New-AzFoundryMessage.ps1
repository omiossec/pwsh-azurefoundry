#Requires -Version 7.4

function New-AzFoundryMessage {
    <#
    .SYNOPSIS
        Builds a chat message for Invoke-AzFoundryChat -Message.
    .DESCRIPTION
        Creates an AzFoundryMessage (system, user, assistant or tool message). Build a conversation by putting
        several messages in an array or a list, and pass it to Invoke-AzFoundryChat -Message.

        A tool message answers a tool call requested by the model: use -Role tool with -ToolCallId (the Id of
        the PwshAzureFoundry.ToolCall) and the result of your function as -Content. A -Content that is not a
        string (a hashtable, an object) is converted to compact JSON (ConvertTo-Json -Depth 10).

        The cmdlet only builds an object in memory; it does not call the service.
    .PARAMETER Role
        Role of the message: system, user, assistant or tool.
    .PARAMETER Content
        Text of the message. Accepts pipeline input (one message per item). Objects are converted to JSON.
    .PARAMETER Name
        Optional participant name (letters, digits, '_' and '-', 64 characters at most).
    .PARAMETER ToolCallId
        Id of the tool call this message answers. Required with -Role tool, and only allowed with it.
    .EXAMPLE
        $history = @(
            New-AzFoundryMessage -Role user -Content 'I am going to Paris, what should I see?'
            New-AzFoundryMessage -Role assistant -Content 'Paris, the capital of France, ...'
            New-AzFoundryMessage -Role user -Content 'What is so great about #1?'
        )
        Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Message $history

        Builds a conversation and sends it.
    .EXAMPLE
        New-AzFoundryMessage -Role tool -ToolCallId $call.Id -Content @{ city = 'Paris'; forecast = 'rain' }

        Answers a tool call; the hashtable is sent as {"city":"Paris","forecast":"rain"}.
    .EXAMPLE
        'Summarise this.', 'Translate it to French.' | New-AzFoundryMessage -Role user

        Builds one user message per pipeline item.
    .LINK
        Invoke-AzFoundryChat
    .LINK
        New-AzFoundryTool
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory message object; changes no system state.'
    )]
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    [OutputType('AzFoundryMessage')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Message')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Tool')]
        [ValidateSet('system', 'user', 'assistant', 'tool')]
        [string]$Role,

        [Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'Message')]
        [Parameter(Mandatory, Position = 1, ValueFromPipeline, ParameterSetName = 'Tool')]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Content,

        [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')]
        [string]$Name,

        [Parameter(Mandatory, ParameterSetName = 'Tool')]
        [ValidateNotNullOrEmpty()]
        [string]$ToolCallId
    )

    begin {
        $isTool = $Role -eq 'tool'
        if ($isTool -and $PSCmdlet.ParameterSetName -ne 'Tool') {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message 'A tool message needs -ToolCallId (the Id of the tool call it answers).' `
                        -ErrorId 'AzFoundryToolCallIdMissing' -Category InvalidArgument -TargetObject $Role `
                        -ExceptionType ([System.ArgumentException]) `
                        -RecommendedAction 'Pass -ToolCallId $call.Id ($call is an item of ChatResult.ToolCalls).'))
        }
        if (-not $isTool -and $PSCmdlet.ParameterSetName -eq 'Tool') {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "-ToolCallId is only allowed with -Role tool (got -Role $Role)." `
                        -ErrorId 'AzFoundryToolCallIdNotAllowed' -Category InvalidArgument -TargetObject $Role `
                        -ExceptionType ([System.ArgumentException])))
        }
    }

    process {
        $value = if ($Content -is [psobject]) { $Content.PSObject.BaseObject } else { $Content }
        $text = if ($null -eq $value -or $value -is [string]) {
            [string]$value
        } else {
            ConvertTo-Json -InputObject $value -Depth 10 -Compress
        }

        $message = [AzFoundryMessage]::new($Role, $text)
        if ($PSBoundParameters.ContainsKey('Name')) {
            $message.Name = $Name
        }
        if ($isTool) {
            $message.ToolCallId = $ToolCallId
        }
        $message
    }
}
