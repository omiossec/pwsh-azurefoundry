#Requires -Version 7.4
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Phase 0 spike: deployment lifecycle (PUT/poll/DELETE), embeddings, partner model, 429 burst.
.DESCRIPTION
    Creates temporary deployments on the resource, captures every ARM and data-plane response
    (status, headers, body) to -OutputPath, and deletes the deployments in a finally block.
    Raw output is NOT sanitised.
.EXAMPLE
    ./test/Spikes/Invoke-ManagementSpike.ps1 -ResourceGroupName <resource-group> `
        -AccountName <account> -OutputPath $env:TEMP/spike
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $AccountName,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string] $ArmApiVersion = '2025-06-01',
    [string] $ChatModel = 'Mistral-Large-3',
    [switch] $SkipPartner,
    [switch] $SkipBurst
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$sub = (Get-AzContext).Subscription.Id
$armPath = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices" +
    "/accounts/$AccountName"
$endpoint = "https://$AccountName.services.ai.azure.com"
$log = [System.Collections.Generic.List[object]]::new()

function Save-Capture([string] $Name, $Status, $Headers, [string] $Content) {
    $hdr = [ordered]@{}
    foreach ($k in $Headers.Keys) {
        if ($k -match '^(Azure-AsyncOperation|Location|Retry-After|retry-after-ms|x-ms-request-id|x-ratelimit|Content-Type|x-ms-ratelimit)') {
            $hdr[$k] = ($Headers[$k] -join ', ')
        }
    }
    Set-Content -Path (Join-Path $OutputPath "$Name.json") -Value $Content -NoNewline
    [ordered]@{ name = $Name; status = [int]$Status; headers = $hdr } | ConvertTo-Json -Depth 5 |
        Set-Content -Path (Join-Path $OutputPath "$Name.meta.json")
    $log.Add([pscustomobject]@{ Name = $Name; Status = [int]$Status; Time = (Get-Date -Format 'HH:mm:ss') })
}

function Invoke-Arm([string] $Name, [string] $Method, [string] $Path, $Body) {
    $p = @{ Method = $Method }
    if ($Path -like 'https://*') { $p.Uri = $Path } else { $p.Path = $Path }
    if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    $r = Invoke-AzRestMethod @p
    $h = @{}; foreach ($kv in $r.Headers) { $h[$kv.Key] = $kv.Value }
    Save-Capture $Name $r.StatusCode $h $r.Content
    [pscustomobject]@{ Status = [int]$r.StatusCode; Headers = $h; Content = $r.Content }
}

function Wait-ArmOperation([string] $Name, $Response) {
    $url = $Response.Headers['Azure-AsyncOperation'] | Select-Object -First 1
    if (-not $url) { $url = $Response.Headers['Location'] | Select-Object -First 1 }
    if (-not $url) { return }
    for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 5
        $poll = Invoke-Arm "$Name-poll-$i" GET $url $null
        $state = try { ($poll.Content | ConvertFrom-Json).status } catch { $null }
        if ($poll.Status -eq 200 -and $state -notin 'InProgress', 'Accepted', 'Creating', 'Deleting', 'Running') { return }
        if ($poll.Status -eq 204) { return }
    }
}

function Invoke-Data([string] $Name, [string] $Path, $Body) {
    $r = Invoke-WebRequest -Method POST -Uri "$endpoint$Path" -Headers @{ 'api-key' = (Get-Key) } `
        -Body ($Body | ConvertTo-Json -Depth 10 -Compress) -ContentType 'application/json' -SkipHttpErrorCheck
    $h = @{}; foreach ($kv in $r.Headers.GetEnumerator()) { $h[$kv.Key] = $kv.Value }
    $text = if ($r.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($r.Content) } else { $r.Content }
    Save-Capture $Name $r.StatusCode $h $text
    [pscustomobject]@{ Status = [int]$r.StatusCode; Headers = $h; Content = $text }
}

$keyJson = (Invoke-AzRestMethod -Method POST -Path "$armPath/listKeys?api-version=$ArmApiVersion").Content
$secureKey = ConvertTo-SecureString -String ($keyJson | ConvertFrom-Json).key1 -AsPlainText -Force
Remove-Variable keyJson
function Get-Key { [System.Net.NetworkCredential]::new('', $secureKey).Password }

$created = [System.Collections.Generic.List[string]]::new()
try {
    # --- 0.6 / 0.4 : Microsoft-sold embedding model -------------------------------------------
    $name = 'spike-embed'
    $body = @{ sku = @{ name = 'GlobalStandard'; capacity = 1 }
               properties = @{ model = @{ format = 'OpenAI'; name = 'text-embedding-3-small'; version = '1' } } }
    $put = Invoke-Arm 'arm-deployment-put' PUT "$armPath/deployments/$name`?api-version=$ArmApiVersion" $body
    if ($put.Status -in 200, 201, 202) { $created.Add($name) }
    Wait-ArmOperation 'arm-deployment-put' $put
    Invoke-Arm 'arm-deployment-get' GET "$armPath/deployments/$name`?api-version=$ArmApiVersion" $null | Out-Null

    $embed = @{ model = $name; input = @('The payment integration still fails.', 'Paris is the capital of France.') }
    $e = Invoke-Data 'embedding' '/openai/v1/embeddings' $embed
    for ($i = 0; $e.Status -eq 404 -and $i -lt 12; $i++) {   # new deployments can take a few minutes
        Start-Sleep -Seconds 20; $e = Invoke-Data 'embedding' '/openai/v1/embeddings' $embed
    }
    Invoke-Data 'embedding-dimensions' '/openai/v1/embeddings' (@{ model = $name; input = 'hello'; dimensions = 256 }) | Out-Null

    # --- 0.7 : partner model -----------------------------------------------------------------
    if (-not $SkipPartner) {
        $pname = 'spike-cohere'
        $pbody = @{ sku = @{ name = 'GlobalStandard'; capacity = 1 }
                    properties = @{ model = @{ format = 'Cohere'; name = 'Cohere-embed-v3-english'; version = '1' } } }
        $pput = Invoke-Arm 'arm-deployment-put-partner' PUT "$armPath/deployments/$pname`?api-version=$ArmApiVersion" $pbody
        if ($pput.Status -in 200, 201, 202) {
            $created.Add($pname)
            Wait-ArmOperation 'arm-deployment-put-partner' $pput
            Invoke-Arm 'arm-deployment-get-partner' GET "$armPath/deployments/$pname`?api-version=$ArmApiVersion" $null | Out-Null
            $pe = Invoke-Data 'embedding-partner' '/openai/v1/embeddings' (@{ model = $pname; input = @('hello') })
            for ($i = 0; $pe.Status -eq 404 -and $i -lt 12; $i++) {
                Start-Sleep -Seconds 20; $pe = Invoke-Data 'embedding-partner' '/openai/v1/embeddings' (@{ model = $pname; input = @('hello') })
            }
        }
        Invoke-Arm 'arm-saas-resources' GET "/subscriptions/$sub/resources?`$filter=resourceType eq 'Microsoft.SaaS/resources'&api-version=2021-04-01" $null | Out-Null
    }

    # --- 0.8 : 429 burst -------------------------------------------------------------------------
    if (-not $SkipBurst) {
        $tiny = @{ model = $ChatModel; max_tokens = 1; messages = @(@{ role = 'user'; content = 'hi' }) }
        for ($i = 1; $i -le 30; $i++) {
            $b = Invoke-Data "burst-$i" '/openai/v1/chat/completions' $tiny
            if ($b.Status -eq 429) { Copy-Item (Join-Path $OutputPath "burst-$i.json") (Join-Path $OutputPath 'error-429.json'); Copy-Item (Join-Path $OutputPath "burst-$i.meta.json") (Join-Path $OutputPath 'error-429.meta.json'); break }
        }
    }
}
finally {
    foreach ($d in $created) {
        $del = Invoke-Arm "arm-deployment-delete-$d" DELETE "$armPath/deployments/$d`?api-version=$ArmApiVersion" $null
        Wait-ArmOperation "arm-deployment-delete-$d" $del
    }
    $after = Invoke-Arm 'arm-deployments-after' GET "$armPath/deployments?api-version=$ArmApiVersion" $null
    $log.Add([pscustomobject]@{ Name = 'remaining deployments: ' + ((($after.Content | ConvertFrom-Json).value.name) -join ', '); Status = 0; Time = '' })
    $log | Export-Csv (Join-Path $OutputPath 'mgmt-summary.csv') -NoTypeInformation
    $log
}
