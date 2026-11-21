#Requires -Version 7.4

# Connection to an Azure AI Foundry resource (spec section 4.1).
# The API key is a SecureString and is hidden from default output; ToString() never includes it.
class AzFoundryConnection {
    # Resource base URI, normalised to 'https://<host>' (no path, no trailing slash).
    [string] $Endpoint

    [ValidateSet('ApiKey', 'EntraId')]
    [string] $AuthMode

    hidden [securestring] $ApiKey

    [string] $SubscriptionId
    [string] $ResourceGroupName
    [string] $AccountName

    # Where the connection came from: Session (Connect-AzFoundry), Parameter (-Endpoint/-ApiKey/-UseEntraId
    # on a cmdlet) or Environment (AZURE_FOUNDRY_ENDPOINT / AZURE_FOUNDRY_API_KEY).
    [ValidateSet('Session', 'Parameter', 'Environment')]
    [string] $Source = 'Session'

    AzFoundryConnection() {}

    AzFoundryConnection([string]$endpoint, [string]$authMode) {
        $this.Endpoint    = $endpoint
        $this.AuthMode    = $authMode
        $this.AccountName = [AzFoundryConnection]::GetAccountName($endpoint)
    }

    [AzFoundryConnection] Clone() {
        return [AzFoundryConnection]$this.MemberwiseClone()
    }

    [string] ToString() {
        return '{0} ({1})' -f $this.Endpoint, $this.AuthMode
    }

    # Account name from a '<name>.services.ai.azure.com' / '<name>.openai.azure.com' /
    # '<name>.cognitiveservices.azure.com' endpoint, or $null for any other host (custom domain).
    static [string] GetAccountName([string]$endpoint) {
        if ([string]::IsNullOrWhiteSpace($endpoint)) {
            return $null
        }
        $uri = $null
        if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri)) {
            return $null
        }
        $pattern = '^(?<name>[a-z0-9][a-z0-9-]*)\.(services\.ai|openai|cognitiveservices)\.azure\.com$'
        $match = [regex]::Match($uri.Host.ToLowerInvariant(), $pattern)
        if ($match.Success) {
            return $match.Groups['name'].Value
        }
        return $null
    }

    # True when both endpoints point to the same resource, whichever host form is used.
    static [bool] IsSameResource([string]$first, [string]$second) {
        if ([string]::IsNullOrWhiteSpace($first) -or [string]::IsNullOrWhiteSpace($second)) {
            return $false
        }
        if ([string]::Equals($first.TrimEnd('/'), $second.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        # Host forms of one account are interchangeable, but only on the same port: a key must not follow an
        # explicit non-default port to another listener.
        $firstUri = $null
        $secondUri = $null
        if (-not [uri]::TryCreate($first, [UriKind]::Absolute, [ref]$firstUri) -or
            -not [uri]::TryCreate($second, [UriKind]::Absolute, [ref]$secondUri) -or
            $firstUri.Port -ne $secondUri.Port) {
            return $false
        }
        $firstName  = [AzFoundryConnection]::GetAccountName($first)
        $secondName = [AzFoundryConnection]::GetAccountName($second)
        return [bool]$firstName -and $firstName -eq $secondName
    }
}
