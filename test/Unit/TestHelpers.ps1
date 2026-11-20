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

# --- Management plane fake ----------------------------------------------------------------------------------------
# Call Initialize-TestArm in BeforeEach: it mocks the Az context, the tokens, Start-Sleep and Send-AzFoundryHttpRequest.
# The fake answers each request with the first route whose method matches and whose regex matches the full URI;
# a route with several responses returns them in order and then repeats the last one. Every call is recorded in
# $global:AzFoundryTestArmCalls ({ Method, Uri, Body (parsed JSON or $null), Headers }).
$script:TestSubscriptionId = '00000000-0000-0000-0000-000000000000'
$script:TestAccountPath = "/subscriptions/$script:TestSubscriptionId/resourceGroups/rg-test/providers/" +
    'Microsoft.CognitiveServices/accounts/test-foundry'
$script:TestArmTarget = @{
    ResourceGroupName = 'rg-test'
    AccountName       = 'test-foundry'
    SubscriptionId    = $script:TestSubscriptionId
}

function Initialize-TestArm {
    $global:AzFoundryTestArmRoutes = [System.Collections.Generic.List[object]]::new()
    $global:AzFoundryTestArmCalls = [System.Collections.Generic.List[object]]::new()

    Mock -ModuleName PwshAzureFoundry Import-AzFoundryAzAccounts {}
    Mock -ModuleName PwshAzureFoundry Get-AzContext {
        [pscustomobject]@{
            Account      = [pscustomobject]@{ Id = 'user@example.com' }
            Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111' }
        }
    }
    Mock -ModuleName PwshAzureFoundry Get-AzFoundryAccessToken {
        [pscustomobject]@{
            Token     = ConvertTo-SecureString 'arm-token-0123456789' -AsPlainText -Force
            ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
        }
    }
    Mock -ModuleName PwshAzureFoundry Start-Sleep {}
    Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest {
        $Body = Get-Variable -Name Body -ValueOnly -ErrorAction Ignore
        $Headers = Get-Variable -Name Headers -ValueOnly -ErrorAction Ignore
        $parsed = if ($Body) { $Body | ConvertFrom-Json -Depth 50 }
        $global:AzFoundryTestArmCalls.Add([pscustomobject]@{
                Method = $Method; Uri = [string]$Uri; Body = $parsed; Headers = $Headers
            })
        foreach ($route in $global:AzFoundryTestArmRoutes) {
            if ($route.Method -eq $Method -and [string]$Uri -match $route.Pattern) {
                if ($route.Queue.Count -gt 1) { return $route.Queue.Dequeue() }
                return $route.Queue.Peek()
            }
        }
        throw "No fake ARM route for $Method $Uri"
    }
}

function Add-TestArmRoute {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][object[]]$Response
    )
    $queue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($item in $Response) { $queue.Enqueue($item) }
    $global:AzFoundryTestArmRoutes.Add([pscustomobject]@{ Method = $Method; Pattern = $Pattern; Queue = $queue })
}

# The calls whose method matches and whose URI matches the regex.
function Get-TestArmCall {
    param([string]$Method, [string]$Pattern = '.')
    @($global:AzFoundryTestArmCalls | Where-Object { (-not $Method -or $_.Method -eq $Method) -and $_.Uri -match $Pattern })
}

function Clear-TestArm {
    Remove-Variable -Name AzFoundryTestArmRoutes, AzFoundryTestArmCalls -Scope Global -ErrorAction Ignore
    InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
}
