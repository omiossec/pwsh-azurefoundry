#Requires -Version 7.4

function ConvertTo-AzFoundryEndpoint {
    <#
    .SYNOPSIS
        Validates and normalises a Foundry resource endpoint.
    .DESCRIPTION
        Accepts either host form ('https://<name>.services.ai.azure.com' or 'https://<name>.openai.azure.com')
        with or without a trailing path ('/', '/openai/v1', ...) and returns 'https://<host>' in lower case.

        The endpoint must be an absolute https URI with no user info and no query string (a query string
        could hold a key). Error messages never echo the raw value, only its host.

        -HostForm switches between the two host forms of the same resource (spec section 2.1: both serve
        every route). Hosts that do not follow the '<name>.<suffix>.azure.com' pattern (custom domains,
        private endpoints) are returned as given.
    .PARAMETER Endpoint
        The endpoint to normalise.
    .PARAMETER HostForm
        AsGiven (default) keeps the host; Foundry returns '<name>.services.ai.azure.com'; OpenAI returns
        '<name>.openai.azure.com'.
    .EXAMPLE
        ConvertTo-AzFoundryEndpoint -Endpoint 'https://Lab.openai.azure.com/openai/v1/'

        Returns https://lab.openai.azure.com
    .EXAMPLE
        ConvertTo-AzFoundryEndpoint -Endpoint 'https://lab.openai.azure.com' -HostForm Foundry

        Returns https://lab.services.ai.azure.com
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Endpoint,

        [ValidateSet('AsGiven', 'Foundry', 'OpenAI')]
        [string]$HostForm = 'AsGiven'
    )

    $example = 'https://<resource>.services.ai.azure.com'
    $uri = $null
    if (-not [uri]::TryCreate($Endpoint.Trim(), [System.UriKind]::Absolute, [ref]$uri) -or -not $uri.Host) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message 'The endpoint is not an absolute URI.' `
                    -ErrorId 'AzFoundryEndpointInvalid' -Category InvalidArgument `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction "Use the resource endpoint, for example $example."))
    }

    if ($uri.Scheme -ne 'https') {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "The endpoint must use https (got '$($uri.Scheme)://$($uri.Host)')." `
                    -ErrorId 'AzFoundryEndpointNotHttps' -Category InvalidArgument -TargetObject $uri.Host `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction "Use the https endpoint of the resource, for example $example."))
    }

    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "The endpoint for '$($uri.Host)' must not have user info, a query string or a fragment." `
                    -ErrorId 'AzFoundryEndpointInvalid' -Category InvalidArgument -TargetObject $uri.Host `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction "Pass only the base URI, for example $example, and the key with -ApiKey."))
    }

    $hostName = $uri.Host.ToLowerInvariant()
    if ($HostForm -ne 'AsGiven') {
        $accountName = [AzFoundryConnection]::GetAccountName("https://$hostName")
        if ($accountName) {
            $hostName = if ($HostForm -eq 'Foundry') {
                "$accountName.services.ai.azure.com"
            } else {
                "$accountName.openai.azure.com"
            }
        } else {
            Write-Verbose "Host '$hostName' is not a standard Foundry host; it is kept as given."
        }
    }

    $port = if ($uri.IsDefaultPort) { '' } else { ":$($uri.Port)" }
    "https://$hostName$port"
}
