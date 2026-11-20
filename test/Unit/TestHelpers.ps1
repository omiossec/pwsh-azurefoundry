#Requires -Version 7.4
# Shared by the unit tests. Dot-source it in BeforeAll: . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

# Az.Accounts stubs. Functions take precedence over cmdlets, so the real module is never loaded by the
# unit tests (and CI does not need it). Tests mock them with -ModuleName PwshAzureFoundry.
function global:Get-AzAccessToken {
    [CmdletBinding()]
    param([string]$ResourceUrl, [switch]$AsSecureString)
    throw 'Get-AzAccessToken stub: mock it.'
}
function global:Get-AzContext {
    [CmdletBinding()]
    param()
    throw 'Get-AzContext stub: mock it.'
}

function Import-TestModule {
    Get-Module PwshAzureFoundry | Remove-Module -Force
    Import-Module (Join-Path $PSScriptRoot '../../src/PwshAzureFoundry/PwshAzureFoundry.psd1') -Force
}

function Get-TestFixture {
    param([Parameter(Mandatory)][string]$Name)
    Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "../Fixtures/$Name")
}

# A response as returned by Send-AzFoundryHttpRequest.
function New-TestResponse {
    param(
        [int]$StatusCode = 200,
        [AllowEmptyString()][string]$Content = '',
        [hashtable]$Headers = @{}
    )
    [pscustomobject]@{ StatusCode = $StatusCode; Headers = $Headers; Content = $Content }
}

# A response built from '<name>.json' and '<name>.meta.json' (status and headers).
function Get-TestFixtureResponse {
    param([Parameter(Mandatory)][string]$Name)
    $meta = Get-TestFixture "$Name.meta.json" | ConvertFrom-Json -AsHashtable
    $headers = @{}
    foreach ($key in $meta.headers.Keys) { $headers[$key] = $meta.headers[$key] }
    New-TestResponse -StatusCode $meta.status -Content (Get-TestFixture "$Name.json") -Headers $headers
}

# An object shaped like the output of Invoke-WebRequest (WebResponseObject).
function New-TestWebResponse {
    param(
        [int]$StatusCode = 200,
        [AllowEmptyString()][string]$Content = '',
        [hashtable]$Headers = @{}
    )
    $typed = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Headers.Keys) { $typed[$key] = [string[]]@($Headers[$key]) }
    [pscustomobject]@{ StatusCode = $StatusCode; Headers = $typed; Content = $Content }
}

function New-TestSecureString {
    param([Parameter(Mandatory)][string]$Value)
    ConvertTo-SecureString -String $Value -AsPlainText -Force
}

# JSON with object keys sorted at every level, to compare request bodies whatever the key order.
function ConvertTo-TestCanonicalJson {
    param([Parameter(Mandatory)][AllowNull()][object]$InputObject)
    $json = if ($InputObject -is [string]) { $InputObject } else { ConvertTo-Json -InputObject $InputObject -Depth 30 }
    $parsed = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 30
    ConvertTo-Json -InputObject (ConvertTo-TestSortedObject $parsed) -Depth 30 -Compress
}

function ConvertTo-TestSortedObject {
    param([AllowNull()][object]$Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in @($Value.Keys) | Sort-Object) { $sorted[$key] = ConvertTo-TestSortedObject $Value[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IList]) {
        return , @(foreach ($item in $Value) { ConvertTo-TestSortedObject $item })
    }
    return $Value
}

# Captures the output of an SSE stream fixture as the parsed chunks Invoke-AzFoundryStreamRequest would output.
function Get-TestStreamChunk {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($line in (Get-TestFixture $Name) -split "`r?`n") {
        if ($line -match '^data: (.+)$' -and $Matches[1] -ne '[DONE]') {
            ConvertFrom-Json -InputObject $Matches[1] -Depth 100
        }
    }
}
