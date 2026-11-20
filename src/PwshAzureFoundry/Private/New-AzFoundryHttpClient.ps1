#Requires -Version 7.4

function New-AzFoundryHttpClient {
    <#
    .SYNOPSIS
        Creates the HttpClient used by Invoke-AzFoundryStreamRequest.
    .DESCRIPTION
        Redirects are not followed, so the api-key header never reaches another host. HttpClient.Timeout
        covers the time until the response headers arrive; the body read timeout is handled by the caller.
        The caller must dispose the client. Unit tests mock this function to plug in a fake handler.
    .PARAMETER TimeoutSec
        Connection and response-headers timeout, in seconds.
    .EXAMPLE
        $client = New-AzFoundryHttpClient -TimeoutSec 120
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory HttpClient; changes no system state.'
    )]
    [CmdletBinding()]
    [OutputType([System.Net.Http.HttpClient])]
    param(
        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec
    )

    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.ConnectTimeout = [timespan]::FromSeconds($TimeoutSec)

    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [timespan]::FromSeconds($TimeoutSec)
    $client
}
