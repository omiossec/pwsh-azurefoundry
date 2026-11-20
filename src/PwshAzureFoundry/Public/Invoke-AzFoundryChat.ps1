#Requires -Version 7.4

function Invoke-AzFoundryChat {
    <#
    .SYNOPSIS
        Sends a chat completion request to a model deployed on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls POST /openai/v1/chat/completions on the resource. The deployment is picked by -Model.

        Give the conversation with -Message (AzFoundryMessage objects from New-AzFoundryMessage, or hashtables
        in the wire shape @{ role = ...; content = ... }), or use -Prompt for a single user message.
        -SystemPrompt adds a system message at the start in both cases.

        Only the parameters you pass go into the request, so the defaults of the model apply to the others.
        Parameter ranges are model-specific (Mistral accepts -Temperature 0 to 1 only); the service error is
        passed through.

        Output: one PwshAzureFoundry.ChatResult (Content, FinishReason, ToolCalls, Usage, RateLimit, Message...).
        Append ChatResult.Message to the history to continue the conversation.

        With -Stream, the answer is written to the pipeline as it arrives, one PwshAzureFoundry.ChatChunk
        (Content, FinishReason, Index) per delta; nothing is written to the host. -PassThru adds the aggregated
        ChatResult at the end (it holds the usage and the tool calls). Ctrl+C cancels the request.

        Tool calling: pass tool definitions with -Tool (New-AzFoundryTool). When the model asks for tool calls,
        FinishReason is 'tool_calls' and ToolCalls lists them. The module never runs your functions: run them,
        answer each call with New-AzFoundryMessage -Role tool -ToolCallId, and call the cmdlet again.

        Messages from the pipeline are collected and sent as one conversation. With -Prompt, the cmdlet sends
        one request per pipeline object, and -Model binds from a Name property, so
        Get-AzFoundryDeployment | Invoke-AzFoundryChat -Prompt 'hi' calls every deployment.
    .PARAMETER Model
        Deployment name, for example Mistral-Large-3. Binds from the Name property of pipeline objects.
    .PARAMETER Prompt
        Text of a single user message (shortcut for -Message).
    .PARAMETER Message
        The conversation: AzFoundryMessage objects (New-AzFoundryMessage, ChatResult.Message) or hashtables with
        role and content. Accepts pipeline input.
    .PARAMETER SystemPrompt
        System message added at the start of the conversation.
    .PARAMETER MaxTokens
        Maximum number of tokens to generate (max_tokens).
    .PARAMETER Temperature
        Sampling temperature, 0 to 2 (temperature). The accepted range depends on the model.
    .PARAMETER TopP
        Nucleus sampling, 0 to 1 (top_p).
    .PARAMETER Stop
        Up to four sequences where the model stops generating (stop).
    .PARAMETER Seed
        Seed for a best-effort deterministic sampling (seed).
    .PARAMETER ResponseFormat
        Output format (response_format): 'text', 'json_object', or a hashtable. A hashtable with a 'type' key is
        sent as-is; any other hashtable is a JSON schema definition (name, schema, strict), sent as
        { type = 'json_schema'; json_schema = <hashtable> }.
    .PARAMETER Tool
        Tool definitions (tools): AzFoundryTool objects from New-AzFoundryTool, or hashtables in the wire shape
        @{ type = 'function'; function = @{ name = ...; description = ...; parameters = ... } }.
    .PARAMETER ToolChoice
        How the model uses the tools (tool_choice): auto, none, required, or the name of one function to force.
    .PARAMETER ExtraBody
        Hashtable merged last into the request body, for parameters this cmdlet does not expose. The service
        rejects fields the model does not know (400 unrecognized_request_argument).
    .PARAMETER Stream
        Write the answer to the pipeline as it arrives (PwshAzureFoundry.ChatChunk objects).
    .PARAMETER PassThru
        With -Stream, also output the aggregated PwshAzureFoundry.ChatResult at the end.
    .PARAMETER Raw
        Output the response of the service as parsed JSON instead of a ChatResult. With -Stream, output each raw
        chunk instead of ChatChunk objects.
    .PARAMETER TimeoutSec
        Request timeout in seconds (default 120). With -Stream, the maximum wait between two chunks.
    .PARAMETER Endpoint
        Endpoint of the resource, overriding the session connection (needs -ApiKey or -UseEntraId, unless it is
        the resource of the session).
    .PARAMETER ApiKey
        API key (SecureString) overriding the session authentication.
    .PARAMETER UseEntraId
        Use an Entra ID token (Az.Accounts and Connect-AzAccount) instead of a key.
    .EXAMPLE
        Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Say hello in French.'

        Sends one user message and shows the answer.
    .EXAMPLE
        $history = @(
            New-AzFoundryMessage -Role user -Content 'I am going to Paris, what should I see?'
            New-AzFoundryMessage -Role assistant -Content 'Paris, the capital of France, ...'
            New-AzFoundryMessage -Role user -Content 'What is so great about #1?'
        )
        Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Message $history -MaxTokens 2048 -Temperature 0.8 -TopP 0.1

        Sends a conversation with sampling parameters.
    .EXAMPLE
        Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Count to 10.' -Stream |
            ForEach-Object { Write-Host $_.Content -NoNewline }

        Prints the answer as it arrives.
    .EXAMPLE
        $result = Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Umbrella in Paris today?' -Tool $weather
        if ($result.FinishReason -eq 'tool_calls') { $result.ToolCalls }

        Shows the tool calls requested by the model (see New-AzFoundryTool).
    .NOTES
        The connection comes from, in this order: -Endpoint/-ApiKey/-UseEntraId, the connection set by
        Connect-AzFoundry, then the AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY environment variables.
        An environment variable holds the key in plain text: use it for CI and containers, and prefer
        Connect-AzFoundry interactively.
    .LINK
        New-AzFoundryMessage
    .LINK
        New-AzFoundryTool
    .LINK
        Connect-AzFoundry
    #>
    [CmdletBinding(DefaultParameterSetName = 'Prompt')]
    [OutputType('PwshAzureFoundry.ChatResult', 'PwshAzureFoundry.ChatChunk')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('Name')]
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(Mandatory, Position = 0, ParameterSetName = 'Prompt')]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Message')]
        [ValidateNotNull()]
        [object[]]$Message,

        [ValidateNotNullOrEmpty()]
        [string]$SystemPrompt,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxTokens,

        [ValidateRange(0.0, 2.0)]
        [double]$Temperature,

        [ValidateRange(0.0, 1.0)]
        [double]$TopP,

        [ValidateCount(1, 4)]
        [string[]]$Stop,

        [int]$Seed,

        [ValidateScript({
                $_ -is [System.Collections.IDictionary] -or $_ -in 'text', 'json_object'
            }, ErrorMessage = "-ResponseFormat must be 'text', 'json_object' or a hashtable.")]
        [object]$ResponseFormat,

        [ValidateNotNull()]
        [object[]]$Tool,

        [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')]
        [string]$ToolChoice,

        [hashtable]$ExtraBody,

        [switch]$Stream,

        [switch]$PassThru,

        [switch]$Raw,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [securestring]$ApiKey,

        [switch]$UseEntraId
    )

    begin {
        if ($PassThru -and -not $Stream) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message '-PassThru needs -Stream (without -Stream the cmdlet outputs the ChatResult).' `
                        -ErrorId 'AzFoundryPassThruNeedsStream' -Category InvalidArgument `
                        -ExceptionType ([System.ArgumentException])))
        }

        $connectionParameters = @{}
        foreach ($name in 'Endpoint', 'ApiKey', 'UseEntraId') {
            if ($PSBoundParameters.ContainsKey($name)) {
                $connectionParameters[$name] = $PSBoundParameters[$name]
            }
        }
        try {
            $connection = Resolve-AzFoundryConnection @connectionParameters
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        # Request fields that do not depend on the pipeline input.
        $options = [ordered]@{}
        $simple = [ordered]@{
            MaxTokens   = 'max_tokens'
            Temperature = 'temperature'
            TopP        = 'top_p'
            Stop        = 'stop'
            Seed        = 'seed'
        }
        foreach ($name in $simple.Keys) {
            if ($PSBoundParameters.ContainsKey($name)) {
                # Assigned directly: an if expression would unroll a one-item -Stop array to a string.
                $options[$simple[$name]] = $PSBoundParameters[$name]
            }
        }
        if ($PSBoundParameters.ContainsKey('ResponseFormat')) {
            $options['response_format'] = if ($ResponseFormat -is [System.Collections.IDictionary]) {
                if ($ResponseFormat.Contains('type')) {
                    $ResponseFormat
                } else {
                    [ordered]@{ type = 'json_schema'; json_schema = $ResponseFormat }
                }
            } else {
                @{ type = [string]$ResponseFormat }
            }
        }
        try {
            if ($PSBoundParameters.ContainsKey('Tool')) {
                $options['tools'] = @(ConvertTo-AzFoundryRequestTool -InputObject $Tool)
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        if ($PSBoundParameters.ContainsKey('ToolChoice')) {
            $options['tool_choice'] = if ($ToolChoice -in 'auto', 'none', 'required') {
                $ToolChoice
            } else {
                [ordered]@{ type = 'function'; function = @{ name = $ToolChoice } }
            }
        }
        if ($Stream) {
            $options['stream'] = $true
            $options['stream_options'] = @{ include_usage = $true }
        }

        $collected = [System.Collections.Generic.List[object]]::new()

        $invokeChat = {
            param([object[]]$Conversation)

            $messages = [System.Collections.Generic.List[object]]::new()
            if ($SystemPrompt) {
                $messages.Add([AzFoundryMessage]::new('system', $SystemPrompt).ToHashtable())
            }
            foreach ($item in ConvertTo-AzFoundryRequestMessage -InputObject $Conversation) {
                $messages.Add($item)
            }

            $body = [ordered]@{
                model    = $Model
                messages = $messages.ToArray()
            }
            foreach ($key in $options.Keys) {
                $body[$key] = $options[$key]
            }
            if ($ExtraBody) {
                foreach ($key in $ExtraBody.Keys) {
                    $body[$key] = $ExtraBody[$key]
                }
            }

            $path = '/openai/v1/chat/completions'
            Write-Verbose ('Chat with {0}: {1} message(s){2}.' -f $Model, $messages.Count,
                $(if ($Stream) { ', streaming' }))

            if (-not $Stream) {
                $response = Invoke-AzFoundryRequest -Connection $connection -Path $path -Body $body `
                    -TimeoutSec $TimeoutSec -IncludeResponseInfo
                if ($Raw) {
                    return $response.Content
                }
                $result = ConvertTo-AzFoundryChatResult -Response $response.Content -Headers $response.Headers
                Write-Verbose ('Finish reason: {0}; tokens: {1}.' -f $result.FinishReason, $result.Usage.TotalTokens)
                return $result
            }

            $aggregator = [AzFoundryChatStream]::new()
            $responseHeaders = @{}
            $stream = @{
                Connection      = $connection
                Path            = $path
                Body            = $body
                TimeoutSec      = $TimeoutSec
                ResponseHeaders = $responseHeaders
            }
            # The pipeline (not a foreach over the output) keeps the chunks flowing as they arrive.
            Invoke-AzFoundryStreamRequest @stream | ForEach-Object {
                $chunks = $aggregator.Add($_)
                if ($Raw) { $_ } else { $chunks }
            }
            Write-Verbose ('Stream finished: {0} chunk(s), finish reason {1}.' -f $aggregator.ChunkCount,
                $aggregator.FinishReason)
            if ($PassThru) {
                ConvertTo-AzFoundryChatResult -Response $aggregator.ToCompletion() -Headers $responseHeaders
            }
        }
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Message') {
            foreach ($item in $Message) {
                $collected.Add($item)
            }
            return
        }
        try {
            & $invokeChat @([AzFoundryMessage]::new('user', $Prompt))
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    end {
        if ($PSCmdlet.ParameterSetName -ne 'Message') {
            return
        }
        if ($collected.Count -eq 0) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message 'No message to send.' -ErrorId 'AzFoundryNoMessage' -Category InvalidArgument `
                        -ExceptionType ([System.ArgumentException])))
        }
        try {
            & $invokeChat $collected.ToArray()
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}
