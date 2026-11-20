#Requires -Version 7.4

function Get-AzFoundryRetryDelay {
    <#
    .SYNOPSIS
        Returns how many seconds to wait before the next attempt.
    .DESCRIPTION
        Honours, in this order, the 'retry-after-ms' and 'x-ms-retry-after-ms' headers (milliseconds) and the
        'Retry-After' header (seconds or an HTTP date). Without a header, returns -DefaultSeconds when it
        is given, otherwise an exponential backoff (1, 2, 4, ... seconds plus up to 1 s of jitter).
        The result is capped at -MaximumSeconds.
    .PARAMETER Headers
        Response headers (case-insensitive hashtable).
    .PARAMETER Attempt
        Number of the attempt that just failed (1 for the first one).
    .PARAMETER DefaultSeconds
        Delay used when no header is present, instead of the exponential backoff (ARM polling).
    .PARAMETER MaximumSeconds
        Upper bound of the delay.
    .EXAMPLE
        Get-AzFoundryRetryDelay -Headers @{ 'Retry-After' = '6' } -Attempt 1
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [AllowNull()]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$Attempt,

        [ValidateRange(0, 3600)]
        [double]$DefaultSeconds,

        [ValidateRange(0, 3600)]
        [double]$MaximumSeconds = $script:AzFoundryMaxRetryDelaySec
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $delay = $null

    if ($Headers) {
        foreach ($name in 'retry-after-ms', 'x-ms-retry-after-ms') {
            $milliseconds = 0.0
            $value = [string]$Headers[$name]
            $parsed = $value -and [double]::TryParse($value, 'Float', $invariant, [ref]$milliseconds)
            if ($parsed -and $milliseconds -ge 0) {
                $delay = $milliseconds / 1000
                break
            }
        }

        $retryAfter = [string]$Headers['Retry-After']
        if ($null -eq $delay -and $retryAfter) {
            $seconds = 0.0
            $date = [datetimeoffset]::MinValue
            if ([double]::TryParse($retryAfter, 'Float', $invariant, [ref]$seconds) -and $seconds -ge 0) {
                $delay = $seconds
            } elseif ([datetimeoffset]::TryParse($retryAfter, $invariant, 'AssumeUniversal', [ref]$date)) {
                $delay = [math]::Max(0, ($date - [datetimeoffset]::UtcNow).TotalSeconds)
            }
        }
    }

    if ($null -eq $delay) {
        $delay = if ($PSBoundParameters.ContainsKey('DefaultSeconds')) {
            $DefaultSeconds
        } else {
            [math]::Pow(2, $Attempt - 1) + (Get-Random -Minimum 0.0 -Maximum 1.0)
        }
    }

    [double][math]::Min($delay, $MaximumSeconds)
}
