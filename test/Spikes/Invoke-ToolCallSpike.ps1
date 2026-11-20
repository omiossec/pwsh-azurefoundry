#Requires -Version 7.4
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Phase 4 spike: checks tool calling on a Foundry resource and saves the raw responses.
.DESCRIPTION
    For each model, calls POST /openai/v1/chat/completions with one tool (get_weather) and a prompt that needs
    it, in these cases:

      toolcall-<model>.json               tool_choice not sent (auto by default)
      toolcall-<model>-required.json      tool_choice = 'required'
      toolcall-<model>-function.json      tool_choice = { type = 'function', function = { name = 'get_weather' } }
      toolcall-<model>-none.json          tool_choice = 'none' (expect text, no tool_calls)
      toolcall-<model>-parallel.json      two tools, a prompt that needs both (parallel calls?)
      toolcall-<model>-roundtrip.json     the assistant tool_calls + tool answers sent back (expect text)
      toolcall-<model>-stream.txt         the parallel case streamed (tool_calls deltas)

    Uses an Entra ID token (Connect-AzAccount first), so no key is handled. Each file holds the status and the
    raw body. Raw output is NOT sanitised: scrub it with ConvertTo-SanitizedFixture.ps1, then replace
    test/Fixtures/synthetic-chat-toolcall*.{json,txt} with the real chat-toolcall.json / chat-toolcall-stream.txt.
.EXAMPLE
    ./test/Spikes/Invoke-ToolCallSpike.ps1 -AccountName <account> -OutputPath $env:TEMP/toolspike `
        -Model 'Mistral-Large-3', 'gpt-4o-mini'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AccountName,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string[]] $Model = @('Mistral-Large-3')
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$uri = "https://$AccountName.services.ai.azure.com/openai/v1/chat/completions"
$token = (Get-AzAccessToken -ResourceUrl 'https://cognitiveservices.azure.com' -AsSecureString).Token
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [timespan]::FromSeconds(120)

$weather = @{
    type     = 'function'
    function = @{
        name        = 'get_weather'
        description = 'Current weather for a city'
        parameters  = @{
            type       = 'object'
            properties = @{ city = @{ type = 'string'; description = 'City name' } }
            required   = @('city')
        }
    }
}
$time = @{
    type     = 'function'
    function = @{
        name        = 'get_time'
        description = 'Current local time in a time zone'
        parameters  = @{
            type       = 'object'
            properties = @{ zone = @{ type = 'string'; description = 'IANA time zone, e.g. Europe/Paris' } }
            required   = @('zone')
        }
    }
}

function Send-Probe {
    param([string] $Name, [hashtable] $Body, [switch] $Stream)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
    $plain = [System.Net.NetworkCredential]::new('', $token).Password
    [void]$request.Headers.TryAddWithoutValidation('Authorization', "Bearer $plain")
    $plain = $null
    $request.Content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress),
        [System.Text.Encoding]::UTF8, 'application/json')
    $response = $client.Send($request)
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $extension = if ($Stream) { 'txt' } else { 'json' }
    $file = Join-Path $OutputPath "$Name.$extension"
    Set-Content -LiteralPath $file -Value $text -NoNewline
    Set-Content -LiteralPath (Join-Path $OutputPath "$Name.meta.json") -Value (
        @{ name = $Name; status = [int]$response.StatusCode; request = $Body } | ConvertTo-Json -Depth 20)
    Write-Host ('{0,-40} {1}' -f $Name, [int]$response.StatusCode)
    if (-not $Stream -and $response.IsSuccessStatusCode) { $text | ConvertFrom-Json }
}

try {
    foreach ($deployment in $Model) {
        $tag = $deployment.ToLowerInvariant()
        $ask = @(@{ role = 'user'; content = 'Do I need an umbrella in Paris today?' })
        $both = @(@{ role = 'user'; content = 'What is the weather in Paris, and what time is it there?' })

        $first = Send-Probe "toolcall-$tag" @{ model = $deployment; messages = $ask; tools = @($weather) }
        $null = Send-Probe "toolcall-$tag-required" @{
            model = $deployment; messages = $ask; tools = @($weather); tool_choice = 'required'
        }
        $null = Send-Probe "toolcall-$tag-function" @{
            model = $deployment; messages = $ask; tools = @($weather)
            tool_choice = @{ type = 'function'; function = @{ name = 'get_weather' } }
        }
        $null = Send-Probe "toolcall-$tag-none" @{
            model = $deployment; messages = $ask; tools = @($weather); tool_choice = 'none'
        }
        $null = Send-Probe "toolcall-$tag-parallel" @{ model = $deployment; messages = $both; tools = @($weather, $time) }
        $null = Send-Probe "toolcall-$tag-stream" -Stream @{
            model = $deployment; messages = $both; tools = @($weather, $time)
            stream = $true; stream_options = @{ include_usage = $true }
        }

        $message = $first.choices[0].message
        if ($message.tool_calls) {
            $history = [System.Collections.Generic.List[object]]::new()
            $history.AddRange([object[]]$ask)
            $history.Add($message)
            foreach ($call in $message.tool_calls) {
                $history.Add(@{
                        role = 'tool'; tool_call_id = $call.id
                        content = '{"city":"Paris","forecast":"rain","tempC":11}'
                    })
            }
            $null = Send-Probe "toolcall-$tag-roundtrip" @{
                model = $deployment; messages = $history.ToArray(); tools = @($weather)
            }
        } else {
            Write-Warning "$deployment returned no tool_calls for the first probe; round trip skipped."
        }
    }
} finally {
    $client.Dispose()
}
