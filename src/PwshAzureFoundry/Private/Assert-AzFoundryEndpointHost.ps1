#Requires -Version 7.4

function Assert-AzFoundryEndpointHost {
    <#
    .SYNOPSIS
        Refuses an endpoint outside Azure unless the caller allows it.
    .DESCRIPTION
        A key or an Entra ID token goes to the endpoint host. An Entra token for the Cognitive Services audience
        works against every Azure AI resource the user can reach, so a mistyped or tampered endpoint must not
        receive it silently.

        Hosts ending with one of $script:AzFoundryAzureHostSuffixes ('.services.ai.azure.com',
        '.openai.azure.com', '.cognitiveservices.azure.com') pass. Any other host (custom domain, gateway) is a
        terminating SecurityError, unless -AllowCustomEndpoint is given: then it passes with a warning, once per
        host and session.
    .PARAMETER Endpoint
        Normalised endpoint (ConvertTo-AzFoundryEndpoint).
    .PARAMETER AllowCustomEndpoint
        Accept a host outside Azure, with a warning.
    .PARAMETER Source
        Where the endpoint comes from, for the recommended action: Parameter (default) or Environment.
    .EXAMPLE
        Assert-AzFoundryEndpointHost -Endpoint 'https://ai.contoso.com' -AllowCustomEndpoint
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [switch]$AllowCustomEndpoint,

        [ValidateSet('Parameter', 'Environment')]
        [string]$Source = 'Parameter'
    )

    $hostName = ([uri]$Endpoint).Host.ToLowerInvariant()
    foreach ($suffix in $script:AzFoundryAzureHostSuffixes) {
        if ($hostName.EndsWith($suffix, [StringComparison]::Ordinal) -and $hostName.Length -gt $suffix.Length) {
            return
        }
    }

    if (-not $AllowCustomEndpoint) {
        $action = if ($Source -eq 'Environment') {
            "$script:AzFoundryEndpointEnvVar accepts only Azure hosts. If you trust $hostName, run " +
            "Connect-AzFoundry -Endpoint <endpoint> -AllowCustomEndpoint."
        } else {
            "Check the endpoint. If you trust $hostName (custom domain or gateway), add -AllowCustomEndpoint."
        }
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "'$hostName' is not an Azure AI Foundry host; the key or token is not sent to it." `
                    -ErrorId 'AzFoundryEndpointNotAzure' -Category SecurityError -TargetObject $hostName `
                    -ExceptionType ([System.ArgumentException]) -RecommendedAction $action))
    }

    if ($script:AzFoundryCustomHostWarned.Add($hostName)) {
        Write-Warning ("'$hostName' is not an Azure AI Foundry host: the key or token is sent to it " +
            '(-AllowCustomEndpoint).')
    }
}
