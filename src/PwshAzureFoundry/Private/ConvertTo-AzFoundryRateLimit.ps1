#Requires -Version 7.4

function ConvertTo-AzFoundryRateLimit {
    <#
    .SYNOPSIS
        Reads the x-ratelimit-* response headers into a PwshAzureFoundry.RateLimit object.
    .DESCRIPTION
        Returns RemainingRequests, RemainingTokens, LimitRequests, LimitTokens, ResetRequests and
        ResetTokens (seconds) as integers ($null when a header is missing), or nothing when the response has
        no rate-limit header at all (spec section 8).
    .PARAMETER Headers
        Response headers (case-insensitive hashtable).
    .EXAMPLE
        ConvertTo-AzFoundryRateLimit -Headers $response.Headers
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.RateLimit')]
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Headers
    )

    if (-not $Headers) {
        return
    }

    $map = [ordered]@{
        RemainingRequests = 'x-ratelimit-remaining-requests'
        RemainingTokens   = 'x-ratelimit-remaining-tokens'
        LimitRequests     = 'x-ratelimit-limit-requests'
        LimitTokens       = 'x-ratelimit-limit-tokens'
        ResetRequests     = 'x-ratelimit-reset-requests'
        ResetTokens       = 'x-ratelimit-reset-tokens'
    }

    $found = $false
    $result = [ordered]@{ PSTypeName = 'PwshAzureFoundry.RateLimit' }
    foreach ($property in $map.Keys) {
        $headerName = $map[$property]
        $value = $null
        foreach ($key in $Headers.Keys) {
            if ([string]::Equals([string]$key, $headerName, [StringComparison]::OrdinalIgnoreCase)) {
                $number = 0
                if ([int]::TryParse(([string]$Headers[$key] -split ',')[0].Trim(), [ref]$number)) {
                    $value = $number
                    $found = $true
                }
                break
            }
        }
        $result[$property] = $value
    }

    if ($found) {
        [pscustomobject]$result
    }
}
