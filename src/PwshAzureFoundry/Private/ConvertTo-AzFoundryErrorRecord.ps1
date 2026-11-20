#Requires -Version 7.4

function ConvertTo-AzFoundryErrorRecord {
    <#
    .SYNOPSIS
        Maps a failed HTTP response to an ErrorRecord.
    .DESCRIPTION
        Normalises the body with ConvertFrom-AzFoundryErrorResponse, then picks the error category and a
        recommended action (spec section 8):

          content_filter / ResponsibleAIPolicyViolation   SecurityError
          401                                             AuthenticationError
          403                                             PermissionDenied
          404, DeploymentNotFound                         ObjectNotFound (hint: Get-AzFoundryDeployment)
          DeploymentCreating                              ResourceBusy
          400, 422                                        InvalidArgument
          409                                             ResourceExists
          429                                             LimitsExceeded
          5xx                                             ResourceUnavailable

        The exception is an HttpRequestException carrying the status code, and its Data['AzFoundryError']
        holds the normalised error. The message is cleaned with Hide-AzFoundrySecret and contains the URI
        without its query string.
    .PARAMETER Response
        Response from Send-AzFoundryHttpRequest (StatusCode, Headers, Content).
    .PARAMETER Method
        HTTP method of the request.
    .PARAMETER Uri
        URI of the request.
    .PARAMETER Secret
        Plain-text secrets used by the request, masked in the message.
    .EXAMPLE
        $PSCmdlet.ThrowTerminatingError((ConvertTo-AzFoundryErrorRecord -Response $r -Method POST -Uri $uri))
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [psobject]$Response,

        [Parameter(Mandatory)]
        [string]$Method,

        [Parameter(Mandatory)]
        [uri]$Uri,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Secret
    )

    $status = [int]$Response.StatusCode
    $serviceError = ConvertFrom-AzFoundryErrorResponse -StatusCode $status -Content ([string]$Response.Content)
    $code = $serviceError.Code

    $category = [System.Management.Automation.ErrorCategory]::NotSpecified
    $hint = $null
    if ($code -eq 'content_filter' -or $serviceError.InnerCode -eq 'ResponsibleAIPolicyViolation') {
        $category = 'SecurityError'
        $hint = 'The content filter of the deployment blocked the prompt or the completion. Rephrase the request.'
    } elseif ($status -eq 401) {
        $category = 'AuthenticationError'
        $hint = 'Check the API key (Get-AzFoundryEndpoint -IncludeKey) or the Entra ID sign-in (Connect-AzAccount).'
    } elseif ($status -eq 403) {
        $category = 'PermissionDenied'
        $hint = 'Inference needs the Cognitive Services User role; deployments need Cognitive Services Contributor.'
    } elseif ($code -eq 'DeploymentCreating') {
        $category = 'ResourceBusy'
        $hint = 'The deployment is still being created. Wait until Get-AzFoundryDeployment shows Succeeded.'
    } elseif ($status -eq 404 -or $code -eq 'DeploymentNotFound') {
        $category = 'ObjectNotFound'
        $hint = ('List the deployments with Get-AzFoundryDeployment. A new deployment can take about 20 seconds ' +
            'to become reachable.')
    } elseif ($status -in 400, 422) {
        $category = 'InvalidArgument'
    } elseif ($status -eq 409) {
        $category = 'ResourceExists'
    } elseif ($status -eq 429) {
        $category = 'LimitsExceeded'
        $hint = 'The deployment is rate limited. Retry later or raise its capacity (requests and tokens per minute).'
    } elseif ($status -ge 500) {
        $category = 'ResourceUnavailable'
        $hint = 'The service failed to answer. Retry later.'
    }

    $logUri = ConvertTo-AzFoundryLogUri -Uri $Uri
    $text = '{0} {1} failed with HTTP {2} ({3}): {4}' -f $Method.ToUpperInvariant(), $logUri, $status, $code,
    $serviceError.Message
    $text = Hide-AzFoundrySecret -Text $text -Secret $Secret
    $serviceError.Message = Hide-AzFoundrySecret -Text $serviceError.Message -Secret $Secret

    $exception = [System.Net.Http.HttpRequestException]::new($text, $null,
        [System.Enum]::ToObject([System.Net.HttpStatusCode], $status))
    $exception.Data['AzFoundryError'] = $serviceError

    $idSuffix = $code -replace '[^A-Za-z0-9_]', ''
    if (-not $idSuffix -or $idSuffix -match '^\d+$') {
        $idSuffix = "Http$status"
    }

    New-AzFoundryErrorRecord -Exception $exception -Message $text -ErrorId "AzFoundry.$idSuffix" `
        -Category $category -TargetObject $logUri -RecommendedAction $hint
}
