#Requires -Version 7.4

function ConvertTo-AzFoundryChatResult {
    <#
    .SYNOPSIS
        Converts a chat completion response to a PwshAzureFoundry.ChatResult object.
    .DESCRIPTION
        Maps the first choice of the response (spec section 5.2):

          Content, Role, FinishReason    choices[0].message.content / role, choices[0].finish_reason
          ToolCalls                      PwshAzureFoundry.ToolCall objects (ConvertTo-AzFoundryToolCall)
          Model, Id                      model (the lower-case model name), id
          Created                        created (Unix seconds) as a DateTimeOffset (UTC)
          Usage                          PwshAzureFoundry.ChatUsage { PromptTokens, CompletionTokens, TotalTokens }
          RateLimit                      x-ratelimit-* headers (ConvertTo-AzFoundryRateLimit)
          Message                        AzFoundryMessage (with the tool calls), ready to append to the history
          Raw                            the response object
    .PARAMETER Response
        Parsed chat completion response.
    .PARAMETER Headers
        Response headers, for the rate-limit information.
    .EXAMPLE
        ConvertTo-AzFoundryChatResult -Response $response.Content -Headers $response.Headers
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.ChatResult')]
    param(
        [Parameter(Mandatory)]
        [psobject]$Response,

        [AllowNull()]
        [System.Collections.IDictionary]$Headers
    )

    $choice = @($Response.choices | Where-Object { $null -ne $_ })[0]
    $responseMessage = if ($choice) { $choice.message }

    $role = if ($responseMessage -and $responseMessage.role) { [string]$responseMessage.role } else { 'assistant' }
    $content = if ($responseMessage) { $responseMessage.content }
    if ($null -ne $content -and $content -isnot [string]) {
        # Some models return content parts: [{ type = 'text'; text = '...' }].
        $content = @($content | ForEach-Object { if ($_.text) { $_.text } else { [string]$_ } }) -join ''
    }

    $toolCalls = @()
    if ($responseMessage -and $responseMessage.PSObject.Properties['tool_calls']) {
        $toolCalls = @(ConvertTo-AzFoundryToolCall -ToolCall $responseMessage.tool_calls)
    }

    $message = [AzFoundryMessage]::new($role, [string]$content)
    if ($toolCalls.Count -gt 0) {
        $message.ToolCalls = $toolCalls
    }

    $usage = $null
    if ($Response.PSObject.Properties['usage'] -and $Response.usage) {
        $usage = [pscustomobject]@{
            PSTypeName       = 'PwshAzureFoundry.ChatUsage'
            PromptTokens     = $Response.usage.prompt_tokens
            CompletionTokens = $Response.usage.completion_tokens
            TotalTokens      = $Response.usage.total_tokens
        }
    }

    $created = $null
    $seconds = 0L
    if ($Response.PSObject.Properties['created'] -and [long]::TryParse([string]$Response.created, [ref]$seconds)) {
        $created = [DateTimeOffset]::FromUnixTimeSeconds($seconds)
    }

    [pscustomobject]@{
        PSTypeName   = 'PwshAzureFoundry.ChatResult'
        Content      = $content
        Role         = $role
        FinishReason = if ($choice) { $choice.finish_reason }
        ToolCalls    = $toolCalls
        Model        = $Response.model
        Usage        = $usage
        Id           = $Response.id
        Created      = $created
        RateLimit    = ConvertTo-AzFoundryRateLimit -Headers $Headers
        Message      = $message
        Raw          = $Response
    }
}
