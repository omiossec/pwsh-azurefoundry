#Requires -Version 7.4
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Phase 0 spike: probes the data-plane routes of a Foundry resource and saves the raw responses.
.DESCRIPTION
    Gets an API key with ARM listKeys (kept in memory only, never written or printed), then calls
    chat completions, streaming, decision (/systemone), model info and error cases with key and
    Entra ID auth. Each response (status, selected headers, body) is saved to -OutputPath.
    Raw output is NOT sanitised: scrub it before copying anything to test/Fixtures.
.EXAMPLE
    ./test/Spikes/Invoke-DataPlaneSpike.ps1 -ResourceGroupName <resource-group> `
        -AccountName <account> -OutputPath $env:TEMP/spike
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AccountName,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string] $ChatModel = 'Mistral-Large-3',
    [string] $DecisionModel = 'Decision-1.1'
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$sub = (Get-AzContext).Subscription.Id
$armPath = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices" +
    "/accounts/$AccountName"

# --- key via listKeys (shape saved with values masked) ---------------------------------------------
$keysResponse = Invoke-AzRestMethod -Method POST -Path "$armPath/listKeys?api-version=2025-06-01"
$keys = $keysResponse.Content | ConvertFrom-Json
$apiKey = ConvertTo-SecureString -String $keys.key1 -AsPlainText -Force
$masked = $keys.PSObject.Properties | ForEach-Object -Begin { $h = [ordered]@{} } `
    -Process { $h[$_.Name] = '<redacted>' } -End { $h }
$masked | ConvertTo-Json | Set-Content (Join-Path $OutputPath 'arm-listKeys.json')
Remove-Variable keys, keysResponse

$services = "https://$AccountName.services.ai.azure.com"
$openai = "https://$AccountName.openai.azure.com"

$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [timespan]::FromSeconds(120)
$results = [System.Collections.Generic.List[object]]::new()

function Get-Token([string] $Resource) {
    $t = Get-AzAccessToken -ResourceUrl $Resource
    if ($t.Token -is [securestring]) { return $t.Token }
    return ConvertTo-SecureString -String $t.Token -AsPlainText -Force
}

function Invoke-Probe {
    param(
        [string] $Name, [string] $Method = 'POST', [string] $Uri, [object] $Body,
        [ValidateSet('Bearer', 'ApiKey', 'None')] [string] $Auth = 'Bearer',
        [securestring] $Secret = $apiKey, [hashtable] $Headers = @{}, [switch] $Stream
    )
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    $plain = if ($Auth -ne 'None') { [System.Net.NetworkCredential]::new('', $Secret).Password }
    switch ($Auth) {
        'Bearer' { $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $plain) }
        'ApiKey' { $req.Headers.Add('api-key', $plain) }
    }
    $plain = $null
    foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $req.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $option = if ($Stream) { [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead } else { [System.Net.Http.HttpCompletionOption]::ResponseContentRead }
    $resp = $client.SendAsync($req, $option).GetAwaiter().GetResult()
    $content = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $sw.Stop()
    $hdr = [ordered]@{}
    foreach ($h in @($resp.Headers) + @($resp.Content.Headers)) {
        if ($h.Key -match '^(content-type|x-ms-region|apim-request-id|x-request-id|x-ratelimit|retry-after|x-ms-deployment-name|x-ms-client-request-id|azureml-model-session|x-ms-rai)') {
            $hdr[$h.Key] = ($h.Value -join ', ')
        }
    }
    $record = [ordered]@{
        name = $Name; method = $Method; uri = $Uri; auth = $Auth; status = [int]$resp.StatusCode
        elapsedMs = $sw.ElapsedMilliseconds; headers = $hdr
    }
    $ext = if ($Stream) { 'txt' } else { 'json' }
    $file = Join-Path $OutputPath "$Name.$ext"
    Set-Content -Path $file -Value $content -NoNewline
    $record | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath "$Name.meta.json")
    $results.Add([pscustomobject]@{ Name = $Name; Status = [int]$resp.StatusCode; Ms = $sw.ElapsedMilliseconds; Auth = $Auth; Uri = $Uri })
    $resp.Dispose(); $req.Dispose()
}

function Copy-Body($b) { $c = [ordered]@{}; foreach ($k in $b.Keys) { $c[$k] = $b[$k] }; $c }

$smallChat = [ordered]@{
    model = $ChatModel; max_tokens = 16
    messages = @(@{ role = 'user'; content = 'Reply with the single word: pong' })
}

# --- 0.1 chat: hosts x auth headers --------------------------------------------------------------
Invoke-Probe -Name 'chat-openai-v1-bearer'   -Uri "$openai/openai/v1/chat/completions" -Body $smallChat
Invoke-Probe -Name 'chat-openai-v1-apikey'   -Uri "$openai/openai/v1/chat/completions" -Body $smallChat -Auth ApiKey
Invoke-Probe -Name 'chat-services-openai-v1-bearer' -Uri "$services/openai/v1/chat/completions" -Body $smallChat
Invoke-Probe -Name 'chat-services-openai-v1-apikey' -Uri "$services/openai/v1/chat/completions" -Body $smallChat -Auth ApiKey
Invoke-Probe -Name 'chat-models-bearer' -Uri "$services/models/chat/completions?api-version=2025-04-01" -Body $smallChat
Invoke-Probe -Name 'chat-models-apikey' -Uri "$services/models/chat/completions?api-version=2025-04-01" -Body $smallChat -Auth ApiKey

# brief payload (multi-turn), max_tokens reduced to limit cost
$brief = [ordered]@{
    messages = @(
        @{ role = 'user'; content = 'I am going to Paris, what should I see?' }
        @{ role = 'assistant'; content = 'Paris has the Eiffel Tower, the Louvre Museum and Notre-Dame Cathedral.' }
        @{ role = 'user'; content = 'What is so great about #1?' }
    )
    max_tokens = 150; temperature = 0.8; top_p = 0.1; model = $ChatModel
}
Invoke-Probe -Name 'chat-brief-payload' -Uri "$openai/openai/v1/chat/completions" -Body $brief

# --- 0.2 streaming ------------------------------------------------------------------------------
$streamBody = [ordered]@{
    model = $ChatModel; max_tokens = 40; stream = $true; stream_options = @{ include_usage = $true }
    messages = @(@{ role = 'user'; content = 'Count from 1 to 10, separated by spaces.' })
}
Invoke-Probe -Name 'chat-stream' -Uri "$openai/openai/v1/chat/completions" -Body $streamBody -Stream

# --- 0.3 decision -------------------------------------------------------------------------------
$decisionBrief = [ordered]@{
    model = $DecisionModel
    state = 'The payment integration still fails. Please help today.'
    questions = [ordered]@{ urgent = [ordered]@{ type = 'noul'; instructions = 'Does this message convey urgency?' } }
}
Invoke-Probe -Name 'decision-predicate' -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionBrief
Invoke-Probe -Name 'decision-predicate-apikey' -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionBrief -Auth ApiKey
Invoke-Probe -Name 'decision-openai-host' -Uri "$openai/providers/microsoft/v1/systemone" -Body $decisionBrief

$decisionAll = [ordered]@{
    model = $DecisionModel
    state = [ordered]@{ subject = 'Charged twice'; body = 'My invoice is wrong, I was charged twice this month. Fix it now!' }
    questions = [ordered]@{
        billing  = [ordered]@{ type = 'noul'; instructions = 'Is this ticket about billing?' }
        team     = [ordered]@{ type = 'choice'; criteria = [ordered]@{ sales = 'Sales'; support = 'Support'; finance = 'Finance' } }
        priority = [ordered]@{ type = 'score'; criteria = @('low', 'medium', 'high') }
    }
}
Invoke-Probe -Name 'decision-all-types' -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionAll
$decisionWrongModel = (Copy-Body $decisionBrief); $decisionWrongModel.model = 'Decision-1'
Invoke-Probe -Name 'error-decision-unknown-model' -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionWrongModel
$decisionBad = [ordered]@{ model = $DecisionModel; state = 'x'; questions = [ordered]@{ q = [ordered]@{ type = 'nope' } } }
Invoke-Probe -Name 'error-decision-bad-question' -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionBad

# --- model info ---------------------------------------------------------------------------------
Invoke-Probe -Name 'models-info' -Method GET -Uri "$services/models/info?api-version=2025-04-01" -Body $null `
    -Headers @{ 'x-ms-model-mesh-model-name' = $ChatModel }
Invoke-Probe -Name 'openai-v1-models' -Method GET -Uri "$openai/openai/v1/models" -Body $null

# --- 0.8 errors ---------------------------------------------------------------------------------
$badKey = ConvertTo-SecureString -String ('0' * 32) -AsPlainText -Force
Invoke-Probe -Name 'error-401-bearer' -Uri "$openai/openai/v1/chat/completions" -Body $smallChat -Secret $badKey
Invoke-Probe -Name 'error-401-apikey' -Uri "$openai/openai/v1/chat/completions" -Body $smallChat -Auth ApiKey -Secret $badKey
$unknown = (Copy-Body $smallChat); $unknown.model = 'does-not-exist'
Invoke-Probe -Name 'error-unknown-deployment' -Uri "$openai/openai/v1/chat/completions" -Body $unknown
$badParam = (Copy-Body $smallChat); $badParam.temperature = 5
Invoke-Probe -Name 'error-invalid-temperature' -Uri "$openai/openai/v1/chat/completions" -Body $badParam
$extra = (Copy-Body $smallChat); $extra.not_a_real_param = 1
Invoke-Probe -Name 'error-unknown-param-models' -Uri "$services/models/chat/completions?api-version=2025-04-01" -Body $extra
Invoke-Probe -Name 'error-unknown-param-openai' -Uri "$openai/openai/v1/chat/completions" -Body $extra

# --- 0.5 Entra ID scopes ------------------------------------------------------------------------
foreach ($scope in 'https://cognitiveservices.azure.com', 'https://ai.azure.com') {
    $tag = ([uri]$scope).Host.Split('.')[0]
    try { $token = Get-Token $scope } catch { $results.Add([pscustomobject]@{ Name = "entra-token-$tag"; Status = 'token-failed'; Auth = $_.Exception.Message }); continue }
    Invoke-Probe -Name "entra-$tag-chat-openai" -Uri "$openai/openai/v1/chat/completions" -Body $smallChat -Secret $token
    Invoke-Probe -Name "entra-$tag-chat-models" -Uri "$services/models/chat/completions?api-version=2025-04-01" -Body $smallChat -Secret $token
    Invoke-Probe -Name "entra-$tag-decision" -Uri "$services/providers/microsoft/v1/systemone" -Body $decisionBrief -Secret $token
}

$client.Dispose()
$results | Export-Csv (Join-Path $OutputPath 'summary.csv') -NoTypeInformation
$results
