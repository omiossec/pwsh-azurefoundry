#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry
<#
.SYNOPSIS
    Tool calling: the model asks for a function, the script runs it and sends the result back.
.DESCRIPTION
    Uses the current connection (Connect-AzFoundry, or the AZURE_FOUNDRY_* environment variables). The module
    never runs your functions: this script reads ChatResult.ToolCalls, runs its own code for each call,
    answers with a tool message, and calls the model again until it gives a text answer.

    Get-Weather is a stub that returns made-up data.
.PARAMETER Model
    Chat deployment name. The model must support tools (Mistral-Large-3 does).
.PARAMETER Prompt
    The question for the model.
.EXAMPLE
    ./samples/tool-calling.ps1 -Prompt 'Do I need an umbrella in Paris or in Lyon today?'
#>
[CmdletBinding()]
param(
    [string] $Model = 'Mistral-Large-3',

    [string] $Prompt = 'Do I need an umbrella in Paris today?'
)

$ErrorActionPreference = 'Stop'

function Get-Weather {
    param([string] $City)
    @{ city = $City; forecast = 'rain'; temperatureC = 11 }   # your own code here
}

$tools = @(
    New-AzFoundryTool -Name 'get_weather' -Description 'Current weather for a city' -Parameter @{
        type       = 'object'
        properties = @{ city = @{ type = 'string'; description = 'City name' } }
        required   = @('city')
    }
)

$history = [System.Collections.Generic.List[object]]::new()
$history.Add((New-AzFoundryMessage -Role user -Content $Prompt))

for ($round = 1; $round -le 5; $round++) {
    $result = Invoke-AzFoundryChat -Model $Model -Message $history -Tool $tools
    if ($result.FinishReason -ne 'tool_calls') { break }

    $history.Add($result.Message)
    foreach ($call in $result.ToolCalls) {
        Write-Verbose "Model calls $($call.Name) $($call.ArgumentsJson)"
        $answer = switch ($call.Name) {
            'get_weather' { Get-Weather -City $call.Arguments.city }
            default { @{ error = "Unknown function $($call.Name)" } }
        }
        $history.Add((New-AzFoundryMessage -Role tool -ToolCallId $call.Id -Content $answer))
    }
}
$result.Content
