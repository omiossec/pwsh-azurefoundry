#Requires -Version 7.4

function Send-AzFoundryHttpRequest {
    <#
    .SYNOPSIS
        Sends one HTTP request with retries, timeout and redacted logging.
    .DESCRIPTION
        Low-level sender shared by Invoke-AzFoundryRequest (data plane) and Invoke-AzFoundryArmRequest (ARM).

        - https only; redirects are not followed, so a header such as api-key never reaches another host.
        - Retries $script:AzFoundryRetryableStatusCodes (429, 5xx) up to -MaxRetry times, honouring
          Retry-After / retry-after-ms (Get-AzFoundryRetryDelay). POST retries only
          $script:AzFoundryPostRetryableStatusCodes (429): a 5xx can come after the inference ran and was
          billed. Timeouts are not retried: the service can stall for 35-55 s, and a retry would double the
          wait and the cost.
        - -Verbose shows method, URI, status and elapsed time. -Debug adds the headers (api-key and
          Authorization masked) and the bodies, cleaned with Hide-AzFoundrySecret. URIs are logged without
          their query string, except api-version.

        Returns [pscustomobject]@{ StatusCode; Headers; Content } for every HTTP status, including errors;
        the caller maps errors. Network failures and timeouts are terminating errors.
    .PARAMETER Uri
        Absolute https URI.
    .PARAMETER Method
        HTTP method.
    .PARAMETER Headers
        Request headers, including the authentication header.
    .PARAMETER Body
        JSON request body.
    .PARAMETER TimeoutSec
        Connection and read timeout, in seconds.
    .PARAMETER MaxRetry
        Number of retries after the first attempt.
    .EXAMPLE
        Send-AzFoundryHttpRequest -Uri $uri -Method POST -Headers $headers -Body $json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',

        [hashtable]$Headers = @{},

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Body,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [ValidateRange(0, 10)]
        [int]$MaxRetry = $script:AzFoundryMaxRetry
    )

    $logUri = ConvertTo-AzFoundryLogUri -Uri $Uri
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https') {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Only https URIs are allowed (got $logUri)." `
                    -ErrorId 'AzFoundryUriNotHttps' -Category SecurityError -TargetObject $logUri `
                    -ExceptionType ([System.ArgumentException])))
    }

    $secretHeaders = @('api-key', 'Authorization')
    $secrets = @(
        foreach ($name in $secretHeaders) {
            if ($Headers.ContainsKey($name) -and $Headers[$name]) {
                [string]$Headers[$name]
                [string]$Headers[$name] -replace '^Bearer\s+', ''
            }
        }
    )

    Write-Debug "$Method $logUri"
    foreach ($name in $Headers.Keys | Sort-Object) {
        $shown = if ($name -in $secretHeaders) { '***' } else { $Headers[$name] }
        Write-Debug "  ${name}: $shown"
    }
    if ($Body) {
        Write-Debug "  Body: $(Hide-AzFoundrySecret -Text $Body -Secret $secrets)"
    }

    $request = @{
        Uri                      = $Uri
        Method                   = $Method
        Headers                  = $Headers
        UserAgent                = $script:AzFoundryUserAgent
        SkipHttpErrorCheck       = $true
        MaximumRedirection       = 0
        ConnectionTimeoutSeconds = $TimeoutSec
        OperationTimeoutSeconds  = $TimeoutSec
        ErrorAction              = 'Stop'
        Verbose                  = $false
        Debug                    = $false
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $request['Body'] = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $request['ContentType'] = 'application/json; charset=utf-8'
    }

    $ProgressPreference = 'SilentlyContinue'
    $attempt = 0
    while ($true) {
        $attempt++
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $raw = Invoke-WebRequest @request
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            $stopwatch.Stop()
            $failure = $_.Exception
            $timedOut = $false
            for ($inner = $failure; $inner; $inner = $inner.InnerException) {
                if ($inner -is [System.TimeoutException] -or $inner -is [System.OperationCanceledException]) {
                    $timedOut = $true
                }
            }
            if ($timedOut) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "$Method $logUri timed out after $TimeoutSec s." `
                            -ErrorId 'AzFoundryRequestTimeout' -Category OperationTimeout -TargetObject $logUri `
                            -ExceptionType ([System.TimeoutException]) -InnerException $failure `
                            -RecommendedAction 'The service can stall for 35-55 s. Retry, or raise -TimeoutSec.'))
            }
            $reason = Hide-AzFoundrySecret -Text $failure.Message -Secret $secrets
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "$Method $logUri failed: $reason" `
                        -ErrorId 'AzFoundryConnectionFailed' -Category ConnectionError -TargetObject $logUri `
                        -InnerException $failure `
                        -RecommendedAction 'Check the endpoint (Get-AzFoundryConnection) and the network connection.'))
        }
        $stopwatch.Stop()

        $responseHeaders = @{}
        if ($raw.Headers) {
            foreach ($name in $raw.Headers.Keys) {
                $responseHeaders[$name] = @($raw.Headers[$name]) -join ', '
            }
        }
        $content = $raw.Content
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }
        $response = [pscustomobject]@{
            StatusCode = [int]$raw.StatusCode
            Headers    = $responseHeaders
            Content    = [string]$content
        }

        Write-Verbose ('{0} {1} -> {2} in {3:N0} ms' -f $Method, $logUri, $response.StatusCode,
            $stopwatch.Elapsed.TotalMilliseconds)
        if ($response.Content) {
            $shown = Hide-AzFoundrySecret -Text $response.Content -Secret $secrets
            if ($shown.Length -gt 4000) {
                $shown = $shown.Substring(0, 4000) + '...'
            }
            Write-Debug "  Response: $shown"
        }

        $retryCodes = if ($Method -eq 'POST') {
            $script:AzFoundryPostRetryableStatusCodes
        } else {
            $script:AzFoundryRetryableStatusCodes
        }
        $retryable = $response.StatusCode -in $retryCodes
        if (-not $retryable -or $attempt -gt $MaxRetry) {
            return $response
        }

        $delay = Get-AzFoundryRetryDelay -Headers $response.Headers -Attempt $attempt
        Write-Verbose ('HTTP {0}: retry {1} of {2} in {3:N1} s.' -f $response.StatusCode, $attempt, $MaxRetry, $delay)
        Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))
    }
}
