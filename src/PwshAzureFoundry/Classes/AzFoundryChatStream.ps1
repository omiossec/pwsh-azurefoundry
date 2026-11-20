#Requires -Version 7.4

# Aggregates the chunks of a streamed chat completion (Invoke-AzFoundryChat -Stream).
#
# Add() takes one parsed 'chat.completion.chunk' and returns the PwshAzureFoundry.ChatChunk objects to emit:
# one per choice whose delta has content or a finish reason. Tool call deltas are not emitted; they are
# accumulated by index (id and name from the first delta that has them, argument fragments concatenated).
# ToCompletion() returns the aggregated first choice in the shape of a non-streamed chat completion, so the
# final ChatResult is built by the same mapping (ConvertTo-AzFoundryChatResult).
class AzFoundryChatStream {
    [string] $Id
    [string] $Model
    [object] $Created
    [string] $Role = 'assistant'
    [string] $FinishReason
    [object] $Usage
    [int] $ChunkCount

    hidden [System.Text.StringBuilder] $Content = [System.Text.StringBuilder]::new()
    hidden [bool] $HasContent
    hidden [System.Collections.Generic.SortedDictionary[int, hashtable]] $ToolCalls =
    [System.Collections.Generic.SortedDictionary[int, hashtable]]::new()

    [object[]] Add([object]$chunk) {
        $emitted = [System.Collections.Generic.List[object]]::new()
        if ($null -eq $chunk) {
            return $emitted.ToArray()
        }
        $this.ChunkCount++

        if (-not $this.Id -and $chunk.id) { $this.Id = [string]$chunk.id }
        if (-not $this.Model -and $chunk.model) { $this.Model = [string]$chunk.model }
        if ($null -eq $this.Created -and $chunk.created) { $this.Created = $chunk.created }
        if ($chunk.PSObject.Properties['usage'] -and $chunk.usage) { $this.Usage = $chunk.usage }

        foreach ($choice in @($chunk.choices)) {
            if ($null -eq $choice) {
                continue
            }
            $index = if ($null -ne $choice.index) { [int]$choice.index } else { 0 }
            $delta = $choice.delta
            $text = $null
            if ($delta) {
                if ($delta.PSObject.Properties['content'] -and $null -ne $delta.content) {
                    $text = [string]$delta.content
                }
                if ($index -eq 0) {
                    if ($delta.PSObject.Properties['role'] -and $delta.role) { $this.Role = [string]$delta.role }
                    if ($null -ne $text) {
                        [void]$this.Content.Append($text)
                        $this.HasContent = $true
                    }
                    if ($delta.PSObject.Properties['tool_calls'] -and $delta.tool_calls) {
                        $this.AddToolCalls(@($delta.tool_calls))
                    }
                }
            }
            $finish = $choice.finish_reason
            if ($index -eq 0 -and $finish) {
                $this.FinishReason = [string]$finish
            }
            if (-not [string]::IsNullOrEmpty($text) -or $finish) {
                $emitted.Add([pscustomobject]@{
                        PSTypeName   = 'PwshAzureFoundry.ChatChunk'
                        Content      = $text
                        FinishReason = $finish
                        Index        = $index
                    })
            }
        }
        return $emitted.ToArray()
    }

    hidden [void] AddToolCalls([object[]]$deltas) {
        $position = 0
        foreach ($delta in $deltas) {
            $index = if ($null -ne $delta.index) { [int]$delta.index } else { $position }
            $position++
            if (-not $this.ToolCalls.ContainsKey($index)) {
                $this.ToolCalls[$index] = @{
                    Id        = $null
                    Name      = $null
                    Arguments = [System.Text.StringBuilder]::new()
                }
            }
            $call = $this.ToolCalls[$index]
            if (-not $call.Id -and $delta.id) { $call.Id = [string]$delta.id }
            $function = $delta.function
            if ($function) {
                if (-not $call.Name -and $function.name) { $call.Name = [string]$function.name }
                if ($null -ne $function.arguments) { [void]$call.Arguments.Append([string]$function.arguments) }
            }
        }
    }

    [pscustomobject] ToCompletion() {
        $message = [ordered]@{
            role    = $this.Role
            content = if ($this.HasContent) { $this.Content.ToString() } else { $null }
        }
        if ($this.ToolCalls.Count -gt 0) {
            $message['tool_calls'] = @(
                foreach ($call in $this.ToolCalls.Values) {
                    [pscustomobject]@{
                        id       = $call.Id
                        type     = 'function'
                        function = [pscustomobject]@{ name = $call.Name; arguments = $call.Arguments.ToString() }
                    }
                }
            )
        }
        return [pscustomobject]@{
            id      = $this.Id
            object  = 'chat.completion'
            created = $this.Created
            model   = $this.Model
            choices = @(
                [pscustomobject]@{
                    index         = 0
                    message       = [pscustomobject]$message
                    finish_reason = $this.FinishReason
                }
            )
            usage   = $this.Usage
        }
    }
}
