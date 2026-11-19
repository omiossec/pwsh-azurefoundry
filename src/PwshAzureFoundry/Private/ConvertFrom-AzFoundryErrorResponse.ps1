#Requires -Version 7.4

function ConvertFrom-AzFoundryErrorResponse {
    <#
    .SYNOPSIS
        Normalises a service error body to { Status, Code, Message, Details, InnerCode }.
    .DESCRIPTION
        Handles every body shape seen on the data plane and on ARM (spec section 8):

          {error:{code:"401", message}}                    gateway (code is a string number)
          {error:{type, code, message}}                    OpenAI style
          {error:{code, message, details}}                 Azure style (also ARM, details may be an array)
          {error:{code:400, message, responseCode}}        provisioning deployment (numeric code)
          {detail:[{type, loc[], msg}]}                    systemone 422 validation
          {error:{code:'content_filter', innererror:{code}}} content filter

        A body that is not JSON (or empty) keeps its first 500 characters as the message. Code falls back to
        the HTTP status code.
    .PARAMETER StatusCode
        HTTP status code of the response.
    .PARAMETER Content
        Response body.
    .EXAMPLE
        ConvertFrom-AzFoundryErrorResponse -StatusCode 404 -Content $response.Content
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Content
    )

    $code = $null
    $message = $null
    $details = $null
    $innerCode = $null

    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($Content)) {
        try {
            $parsed = ConvertFrom-Json -InputObject $Content -ErrorAction Stop
        } catch {
            Write-Debug 'The error body is not JSON.'
        }
    }

    $hasProperty = { param($Object, $Name) $Object -is [psobject] -and $Object.PSObject.Properties[$Name] }

    if ((& $hasProperty $parsed 'error') -and $null -ne $parsed.error) {
        $serviceError = $parsed.error
        if ($serviceError -is [string]) {
            $message = $serviceError
        } else {
            $code = if ((& $hasProperty $serviceError 'responseCode') -and $serviceError.responseCode) {
                [string]$serviceError.responseCode
            } else {
                [string]$serviceError.code
            }
            $message = [string]$serviceError.message
            if ((& $hasProperty $serviceError 'details') -and $serviceError.details) {
                $details = $serviceError.details
            } elseif ((& $hasProperty $serviceError 'type') -and $serviceError.type) {
                $details = $serviceError.type
            }
            if ((& $hasProperty $serviceError 'innererror') -and $serviceError.innererror) {
                $innerCode = [string]$serviceError.innererror.code
            }
        }
    } elseif ((& $hasProperty $parsed 'detail') -and $parsed.detail) {
        $code = 'ValidationError'
        $details = $parsed.detail
        $message = if ($parsed.detail -is [string]) {
            $parsed.detail
        } else {
            @(
                foreach ($item in $parsed.detail) {
                    $location = @($item.loc) -join '.'
                    if ($location) { '{0}: {1}' -f $location, $item.msg } else { [string]$item.msg }
                }
            ) -join '; '
        }
    } elseif ((& $hasProperty $parsed 'message') -and $parsed.message) {
        $message = [string]$parsed.message
        if ((& $hasProperty $parsed 'code') -and $parsed.code) {
            $code = [string]$parsed.code
        }
    }

    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = if ([string]::IsNullOrWhiteSpace($Content)) {
            'The service returned no error details.'
        } elseif ($Content.Length -gt 500) {
            $Content.Substring(0, 500) + '...'
        } else {
            $Content.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($code)) {
        $code = [string]$StatusCode
    }

    [pscustomobject]@{
        PSTypeName = 'PwshAzureFoundry.ServiceError'
        Status     = $StatusCode
        Code       = $code
        Message    = $message
        Details    = $details
        InnerCode  = $innerCode
    }
}
