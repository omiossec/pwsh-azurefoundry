#Requires -Version 7.4

function Invoke-AzFoundryArmRequest {
    <#
    .SYNOPSIS
        Calls the Azure Resource Manager API.
    .DESCRIPTION
        Every management call goes through this helper (spec section 4.2):

        - URI: $script:AzFoundryArmBaseUri + -Path + api-version ($script:AzFoundryArmApiVersion by default).
        - Token: Entra ID token for the ARM base URI, from the module token cache (Get-AzFoundryAccessToken).
        - Paging: a GET whose body has a 'value' array outputs each item and follows 'nextLink'.
        - Async operations: a 201/202 with an Azure-AsyncOperation or Location header is polled (GET, every
          Retry-After seconds, $script:AzFoundryArmPollIntervalSec by default) until the operation status is
          terminal. Polls answering 202 continue; a 200 with status Succeeded (or with no status) ends it;
          Failed or Canceled is a terminating error. After success, PUT and PATCH output the resource
          (fresh GET), DELETE outputs nothing, POST outputs the last poll body. -NoWait outputs the first
          response body and returns.
        - A synchronous 200/201 (OpenAI models, spec section 2.1) outputs the body as is.
        - nextLink and polling URLs must stay on the ARM host, or the call stops before sending the token.
          Polling URLs are signed and are never logged with their query string.

        HTTP errors become terminating errors mapped by ConvertTo-AzFoundryErrorRecord.
    .PARAMETER Path
        Resource path starting with /subscriptions/, without api-version.
    .PARAMETER Method
        HTTP method. Defaults to GET.
    .PARAMETER Body
        Request body (serialised to JSON).
    .PARAMETER ApiVersion
        ARM api-version. Defaults to $script:AzFoundryArmApiVersion.
    .PARAMETER NoWait
        Do not poll asynchronous operations.
    .PARAMETER PollTimeoutSec
        Maximum time to wait for an asynchronous operation.
    .EXAMPLE
        $path = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.CognitiveServices/accounts/$name"
        Invoke-AzFoundryArmRequest -Path "$path/deployments"
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^/subscriptions/')]
        [string]$Path,

        [ValidateSet('GET', 'PUT', 'PATCH', 'POST', 'DELETE')]
        [string]$Method = 'GET',

        [object]$Body,

        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion = $script:AzFoundryArmApiVersion,

        [switch]$NoWait,

        [ValidateRange(1, 86400)]
        [int]$PollTimeoutSec = $script:AzFoundryArmPollTimeoutSec
    )

    $armBase = [uri]$script:AzFoundryArmBaseUri
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $resourceUri = '{0}{1}{2}api-version={3}' -f $armBase.AbsoluteUri.TrimEnd('/'), $Path, $separator,
    [uri]::EscapeDataString($ApiVersion)

    # Sends one ARM call and throws the mapped error on an HTTP error.
    $sendArm = {
        param([string]$TargetUri, [string]$TargetMethod, [string]$Json)

        $target = [uri]$TargetUri
        if ($target.Scheme -ne 'https' -or $target.Host -ne $armBase.Host) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message ("ARM returned a link to an unexpected host ($($target.Scheme)://$($target.Host)); " +
                        'the request was not sent.') `
                        -ErrorId 'AzFoundryArmUnexpectedHost' -Category SecurityError -TargetObject $target.Host `
                        -ExceptionType ([System.InvalidOperationException])))
        }

        $token = Get-AzFoundryAccessToken -ResourceUrl $armBase.AbsoluteUri
        $plainToken = ConvertFrom-AzFoundrySecureString -SecureString $token.Token
        $send = @{
            Uri     = $target
            Method  = $TargetMethod
            Headers = @{ Authorization = "Bearer $plainToken" }
        }
        if ($Json) {
            $send['Body'] = $Json
        }
        $result = Send-AzFoundryHttpRequest @send
        if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
            $PSCmdlet.ThrowTerminatingError((ConvertTo-AzFoundryErrorRecord -Response $result `
                        -Method $TargetMethod -Uri $target -Secret $plainToken))
        }
        $result
    }

    $json = $null
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    }

    $response = & $sendArm $resourceUri $Method $json
    $content = ConvertFrom-AzFoundryJsonContent -Content $response.Content

    # Paging.
    $isList = $Method -eq 'GET' -and $content -is [psobject] -and $content.PSObject.Properties['value'] -and
    $content.value -is [array]
    if ($isList) {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        while ($true) {
            foreach ($item in $content.value) {
                $item
            }
            $next = if ($content.PSObject.Properties['nextLink']) { [string]$content.nextLink }
            if (-not $next -or -not $seen.Add($next)) {
                return
            }
            Write-Verbose 'Following nextLink.'
            $content = ConvertFrom-AzFoundryJsonContent -Content (& $sendArm $next 'GET' $null).Content
        }
    }

    # Asynchronous operation.
    $operationUri = $response.Headers['Azure-AsyncOperation']
    if (-not $operationUri) {
        $operationUri = $response.Headers['Location']
    }
    $isAsync = $Method -ne 'GET' -and $response.StatusCode -in 201, 202 -and $operationUri
    if (-not $isAsync -or $NoWait) {
        if ($isAsync) {
            Write-Verbose "$Method $Path accepted (HTTP $($response.StatusCode)); not waiting (-NoWait)."
        }
        if ($null -ne $content) {
            $content
        }
        return
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastResponse = $response
    $pollContent = $null
    $attempt = 0
    while ($true) {
        $attempt++
        $delay = Get-AzFoundryRetryDelay -Headers $lastResponse.Headers -Attempt ([math]::Min($attempt, 100)) `
            -DefaultSeconds $script:AzFoundryArmPollIntervalSec
        if ($stopwatch.Elapsed.TotalSeconds + $delay -gt $PollTimeoutSec) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "$Method $Path did not finish within $PollTimeoutSec s." `
                        -ErrorId 'AzFoundryArmOperationTimeout' -Category OperationTimeout -TargetObject $Path `
                        -ExceptionType ([System.TimeoutException]) `
                        -RecommendedAction 'Check the state of the resource later (Get-AzFoundryDeployment).'))
        }
        Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))

        $lastResponse = & $sendArm $operationUri 'GET' $null
        if ($lastResponse.StatusCode -eq 202) {
            if ($lastResponse.Headers['Location']) {
                $operationUri = $lastResponse.Headers['Location']
            }
            Write-Verbose ('{0} {1}: in progress ({2:N0} s).' -f $Method, $Path, $stopwatch.Elapsed.TotalSeconds)
            continue
        }

        $pollContent = ConvertFrom-AzFoundryJsonContent -Content $lastResponse.Content
        $status = if ($pollContent -is [psobject] -and $pollContent.PSObject.Properties['status']) {
            [string]$pollContent.status
        }
        if (-not $status -or $status -eq 'Succeeded') {
            Write-Verbose ('{0} {1}: Succeeded ({2:N0} s).' -f $Method, $Path, $stopwatch.Elapsed.TotalSeconds)
            break
        }
        if ($status -in 'Failed', 'Canceled', 'Cancelled') {
            $reason = 'no error details'
            if ($pollContent.PSObject.Properties['error'] -and $pollContent.error) {
                $reason = '{0}: {1}' -f $pollContent.error.code, $pollContent.error.message
            }
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "$Method $Path ended with status $($status) ($reason)." `
                        -ErrorId 'AzFoundryArmOperationFailed' -Category InvalidOperation -TargetObject $Path `
                        -ExceptionType ([System.InvalidOperationException])))
        }
        Write-Verbose ('{0} {1}: {2} ({3:N0} s).' -f $Method, $Path, $status, $stopwatch.Elapsed.TotalSeconds)
    }

    $final = switch ($Method) {
        { $_ -in 'PUT', 'PATCH' } {
            ConvertFrom-AzFoundryJsonContent -Content (& $sendArm $resourceUri 'GET' $null).Content
        }
        'POST' {
            $pollContent
        }
    }
    if ($null -ne $final) {
        $final
    }
}
