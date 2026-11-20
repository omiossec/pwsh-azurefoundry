#Requires -Version 7.4

function Invoke-AzFoundryRequest {
    <#
    .SYNOPSIS
        Calls a data-plane route of a Foundry resource.
    .DESCRIPTION
        Every data-plane call (chat, embeddings, decision) goes through this helper. It builds the URI from the
        connection endpoint, adds the authentication header (Get-AzFoundryAuthHeader), serialises the body to
        JSON (-Depth 20, -Compress), sends it with Send-AzFoundryHttpRequest (retries, timeout, redacted
        logging) and returns the parsed JSON.

        HTTP errors become terminating errors mapped by ConvertTo-AzFoundryErrorRecord.
    .PARAMETER Connection
        Resolved connection (Resolve-AzFoundryConnection).
    .PARAMETER Path
        Route, for example /openai/v1/chat/completions.
    .PARAMETER Method
        HTTP method. Defaults to POST.
    .PARAMETER Body
        Request body: a hashtable or object (serialised to JSON) or a JSON string.
    .PARAMETER Query
        Query string parameters. $null values are skipped.
    .PARAMETER TimeoutSec
        Request timeout in seconds. Defaults to $script:AzFoundryDefaultTimeoutSec (120).
    .PARAMETER IncludeResponseInfo
        Return { StatusCode, Headers, Content } instead of the parsed content alone (rate-limit headers).
    .EXAMPLE
        Invoke-AzFoundryRequest -Connection $connection -Path '/openai/v1/chat/completions' -Body $body
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AzFoundryConnection]$Connection,

        [Parameter(Mandatory)]
        [ValidatePattern('^/')]
        [string]$Path,

        [ValidateSet('GET', 'POST', 'DELETE')]
        [string]$Method = 'POST',

        [object]$Body,

        [hashtable]$Query,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [switch]$IncludeResponseInfo
    )

    $uri = $Connection.Endpoint.TrimEnd('/') + $Path
    if ($Query) {
        $pairs = foreach ($key in $Query.Keys | Sort-Object) {
            if ($null -ne $Query[$key]) {
                '{0}={1}' -f [uri]::EscapeDataString($key), [uri]::EscapeDataString([string]$Query[$key])
            }
        }
        if ($pairs) {
            $uri += '?' + ($pairs -join '&')
        }
    }

    $headers = Get-AzFoundryAuthHeader -Connection $Connection
    $send = @{
        Uri        = $uri
        Method     = $Method
        Headers    = $headers
        TimeoutSec = $TimeoutSec
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $send['Body'] = if ($Body -is [string]) {
            $Body
        } else {
            ConvertTo-Json -InputObject $Body -Depth 20 -Compress
        }
    }

    $response = Send-AzFoundryHttpRequest @send
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $secrets = @($headers.Values | ForEach-Object { [string]$_; [string]$_ -replace '^Bearer\s+', '' })
        $PSCmdlet.ThrowTerminatingError((ConvertTo-AzFoundryErrorRecord -Response $response -Method $Method `
                    -Uri $uri -Secret $secrets))
    }

    $content = ConvertFrom-AzFoundryJsonContent -Content $response.Content
    if ($IncludeResponseInfo) {
        [pscustomobject]@{
            PSTypeName = 'PwshAzureFoundry.HttpResponse'
            StatusCode = $response.StatusCode
            Headers    = $response.Headers
            Content    = $content
        }
    } elseif ($null -ne $content) {
        $content
    }
}
