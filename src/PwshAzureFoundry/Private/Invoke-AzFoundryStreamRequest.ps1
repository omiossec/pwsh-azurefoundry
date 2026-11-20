#Requires -Version 7.4

function Invoke-AzFoundryStreamRequest {
    <#
    .SYNOPSIS
        Calls a data-plane route that answers with Server-Sent Events, and outputs each event as it arrives.
    .DESCRIPTION
        Invoke-RestMethod buffers the whole response, so streaming uses System.Net.Http.HttpClient with
        HttpCompletionOption.ResponseHeadersRead (spec section 5.2):

        - The body is read in chunks and parsed by AzFoundrySseParser (multi-line events, keep-alive
          comments, any line ending, chunks split anywhere). Each 'data' payload is parsed as JSON and written
          to the pipeline at once. 'data: [DONE]' ends the stream.
        - An error event (an 'error' event type, or a payload with an 'error' property) is a terminating error
          mapped by ConvertTo-AzFoundryErrorRecord.
        - An HTTP error status before the stream starts is mapped the same way as Invoke-AzFoundryRequest;
          429 and 5xx are retried ($script:AzFoundryMaxRetry, Retry-After honoured).
        - Ctrl+C, or a downstream command that stops the pipeline, cancels the request; the client, the
          response and the cancellation source are always disposed.
        - -TimeoutSec applies to the response headers and to each read of the body (time between two chunks).
        - -Verbose and -Debug log like Send-AzFoundryHttpRequest, with the authentication headers masked.
    .PARAMETER Connection
        Resolved connection (Resolve-AzFoundryConnection).
    .PARAMETER Path
        Route, for example /openai/v1/chat/completions.
    .PARAMETER Body
        Request body: a hashtable or object (serialised to JSON) or a JSON string. It must ask for a stream.
    .PARAMETER TimeoutSec
        Timeout for the response headers and for each read of the body, in seconds.
    .PARAMETER ResponseHeaders
        A hashtable that receives the response headers (for the rate-limit information).
    .EXAMPLE
        Invoke-AzFoundryStreamRequest -Connection $connection -Path '/openai/v1/chat/completions' -Body $body |
            ForEach-Object { $_.choices[0].delta.content }
    #>
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory)]
        [AzFoundryConnection]$Connection,

        [Parameter(Mandatory)]
        [ValidatePattern('^/')]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Body,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [hashtable]$ResponseHeaders
    )

    $uri = [uri]($Connection.Endpoint.TrimEnd('/') + $Path)
    $logUri = ConvertTo-AzFoundryLogUri -Uri $uri
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Only https URIs are allowed (got $logUri)." `
                    -ErrorId 'AzFoundryUriNotHttps' -Category SecurityError -TargetObject $logUri `
                    -ExceptionType ([System.ArgumentException])))
    }

    $headers = Get-AzFoundryAuthHeader -Connection $Connection
    $secrets = @($headers.Values | ForEach-Object { [string]$_; [string]$_ -replace '^Bearer\s+', '' })
    $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 -Compress }

    Write-Debug "POST $logUri (stream)"
    foreach ($name in $headers.Keys | Sort-Object) {
        Write-Debug "  ${name}: ***"
    }
    Write-Debug "  Body: $(Hide-AzFoundrySecret -Text $json -Secret $secrets)"

    # Maps a transport exception (timeout, connection failure) to a terminating error.
    $throwTransportError = {
        param([System.Exception]$Failure, [string]$Stage)
        $timedOut = $false
        for ($inner = $Failure; $inner; $inner = $inner.InnerException) {
            if ($inner -is [System.TimeoutException] -or $inner -is [System.OperationCanceledException]) {
                $timedOut = $true
            }
        }
        if ($timedOut) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "POST $logUri timed out after $TimeoutSec s ($Stage)." `
                        -ErrorId 'AzFoundryRequestTimeout' -Category OperationTimeout -TargetObject $logUri `
                        -ExceptionType ([System.TimeoutException]) -InnerException $Failure `
                        -RecommendedAction 'The service can stall for 35-55 s. Retry, or raise -TimeoutSec.'))
        }
        $reason = Hide-AzFoundrySecret -Text $Failure.Message -Secret $secrets
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "POST $logUri failed ($Stage): $reason" `
                    -ErrorId 'AzFoundryConnectionFailed' -Category ConnectionError -TargetObject $logUri `
                    -InnerException $Failure `
                    -RecommendedAction 'Check the endpoint (Get-AzFoundryConnection) and the network connection.'))
    }

    $client = $null
    $cancellation = $null
    $response = $null
    $reader = $null
    try {
        $client = New-AzFoundryHttpClient -TimeoutSec $TimeoutSec
        $cancellation = [System.Threading.CancellationTokenSource]::new()

        $attempt = 0
        while ($true) {
            $attempt++
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
            foreach ($name in $headers.Keys) {
                [void]$request.Headers.TryAddWithoutValidation($name, [string]$headers[$name])
            }
            [void]$request.Headers.TryAddWithoutValidation('User-Agent', $script:AzFoundryUserAgent)
            [void]$request.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
            $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8,
                'application/json')

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $send = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
                    $cancellation.Token)
                $response = Wait-AzFoundryTask -Task $send -TimeoutSec ($TimeoutSec + 5) -Operation "POST $logUri"
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                & $throwTransportError $_.Exception 'waiting for the response'
            }
            $stopwatch.Stop()

            $status = [int]$response.StatusCode
            Write-Verbose ('POST {0} -> {1} in {2:N0} ms (stream)' -f $logUri, $status,
                $stopwatch.Elapsed.TotalMilliseconds)

            $received = @{}
            foreach ($header in @($response.Headers) + @($response.Content.Headers)) {
                $received[$header.Key] = @($header.Value) -join ', '
            }
            if ($null -ne $ResponseHeaders) {
                $ResponseHeaders.Clear()
                foreach ($key in $received.Keys) {
                    $ResponseHeaders[$key] = $received[$key]
                }
            }

            if ($status -ge 200 -and $status -lt 300) {
                break
            }

            $content = Wait-AzFoundryTask -Task $response.Content.ReadAsStringAsync($cancellation.Token) `
                -TimeoutSec $TimeoutSec -Operation "Reading the error of POST $logUri"
            Write-Debug "  Response: $(Hide-AzFoundrySecret -Text ([string]$content) -Secret $secrets)"
            $response.Dispose()
            $response = $null

            if ($status -in $script:AzFoundryRetryableStatusCodes -and $attempt -le $script:AzFoundryMaxRetry) {
                $delay = Get-AzFoundryRetryDelay -Headers $received -Attempt $attempt
                Write-Verbose ('HTTP {0}: retry {1} of {2} in {3:N1} s.' -f $status, $attempt,
                    $script:AzFoundryMaxRetry, $delay)
                Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))
                continue
            }

            $failed = [pscustomobject]@{ StatusCode = $status; Headers = $received; Content = [string]$content }
            $PSCmdlet.ThrowTerminatingError((ConvertTo-AzFoundryErrorRecord -Response $failed -Method 'POST' `
                        -Uri $uri -Secret $secrets))
        }

        $stream = Wait-AzFoundryTask -Task $response.Content.ReadAsStreamAsync($cancellation.Token) `
            -TimeoutSec $TimeoutSec -Operation "Opening the stream of POST $logUri"
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        $parser = [AzFoundrySseParser]::new()
        $buffer = [char[]]::new(8192)
        $eventCount = 0
        $done = $false

        while (-not $done) {
            try {
                $count = Wait-AzFoundryTask -Task $reader.ReadAsync($buffer, 0, $buffer.Length) `
                    -TimeoutSec $TimeoutSec -Operation "Reading the stream of POST $logUri"
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                & $throwTransportError $_.Exception 'reading the stream'
            }

            if ($count -gt 0) {
                $events = $parser.Push([string]::new($buffer, 0, $count))
            } else {
                $events = $parser.Flush()
                $done = $true
            }

            foreach ($sseEvent in $events) {
                $data = $sseEvent.Data
                if ($data.Trim() -eq '[DONE]') {
                    $done = $true
                    break
                }
                $eventCount++

                $payload = $null
                try {
                    $payload = ConvertFrom-Json -InputObject $data -Depth 100 -ErrorAction Stop
                } catch {
                    if ($sseEvent.Event -ne 'error') {
                        Write-Warning "Skipped a stream event that is not JSON (event $eventCount)."
                        Write-Debug "  Event: $(Hide-AzFoundrySecret -Text $data -Secret $secrets)"
                        continue
                    }
                }

                $isError = $sseEvent.Event -eq 'error' -or
                ($payload -is [psobject] -and $payload.PSObject.Properties['error'] -and $null -ne $payload.error)
                if ($isError) {
                    $errorStatus = 500
                    if ($payload.error.status -as [int]) {
                        $errorStatus = [int]$payload.error.status
                    } elseif (($payload.error.code -as [int]) -ge 400) {
                        $errorStatus = [int]$payload.error.code
                    }
                    $failed = [pscustomobject]@{ StatusCode = $errorStatus; Headers = $received; Content = $data }
                    $PSCmdlet.ThrowTerminatingError((ConvertTo-AzFoundryErrorRecord -Response $failed `
                                -Method 'POST' -Uri $uri -Secret $secrets))
                }

                $payload
            }
        }
        Write-Verbose "Stream of POST $logUri ended after $eventCount events."
    } finally {
        if ($cancellation) {
            $cancellation.Cancel()
        }
        foreach ($disposable in @($reader, $response, $client, $cancellation)) {
            if ($disposable) {
                $disposable.Dispose()
            }
        }
    }
}
