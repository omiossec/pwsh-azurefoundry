#Requires -Version 7.4

function Resolve-AzFoundryConnection {
    <#
    .SYNOPSIS
        Returns the connection a data-plane call should use.
    .DESCRIPTION
        Merges, in this order (spec section 4.1):

          1. explicit parameters (-Endpoint, -ApiKey, -UseEntraId),
          2. the session set by Connect-AzFoundry,
          3. the AZURE_FOUNDRY_ENDPOINT / AZURE_FOUNDRY_API_KEY environment variables.

        -ApiKey or -UseEntraId alone override the authentication of the session (or of the environment).
        -Endpoint alone reuses the session credentials only when it points to the same resource as the
        session; a key is never sent to another resource. The environment key is turned into a SecureString
        as soon as it is read.

        Throws a terminating error when nothing is configured.
    .PARAMETER Endpoint
        Resource endpoint that overrides the session.
    .PARAMETER ApiKey
        API key that overrides the session authentication.
    .PARAMETER UseEntraId
        Use an Entra ID token instead of a key.
    .EXAMPLE
        $connection = Resolve-AzFoundryConnection @PSBoundParameters
    #>
    [CmdletBinding()]
    [OutputType([AzFoundryConnection])]
    param(
        [string]$Endpoint,

        [securestring]$ApiKey,

        [switch]$UseEntraId
    )

    if ($ApiKey -and $UseEntraId) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message '-ApiKey and -UseEntraId cannot be used together.' `
                    -ErrorId 'AzFoundryAuthConflict' -Category InvalidArgument `
                    -ExceptionType ([System.ArgumentException])))
    }

    $session = $script:AzFoundryConnection
    $endpointVar = $script:AzFoundryEndpointEnvVar
    $keyVar = $script:AzFoundryApiKeyEnvVar

    # Applies -ApiKey / -UseEntraId to a connection. Returns $false when neither is given.
    $setAuthFromParameter = {
        param([AzFoundryConnection]$Target)
        if ($ApiKey) {
            $Target.AuthMode = 'ApiKey'
            $Target.ApiKey = $ApiKey
            return $true
        }
        if ($UseEntraId) {
            $Target.AuthMode = 'EntraId'
            $Target.ApiKey = $null
            return $true
        }
        return $false
    }

    # 1. Explicit endpoint.
    if ($PSBoundParameters.ContainsKey('Endpoint')) {
        $normalised = ConvertTo-AzFoundryEndpoint -Endpoint $Endpoint
        $connection = [AzFoundryConnection]::new($normalised, 'ApiKey')
        $connection.Source = 'Parameter'

        $sameResource = $session -and [AzFoundryConnection]::IsSameResource($session.Endpoint, $normalised)
        if ($sameResource) {
            $connection.SubscriptionId    = $session.SubscriptionId
            $connection.ResourceGroupName = $session.ResourceGroupName
            $connection.AccountName       = $session.AccountName
        }

        if (-not (& $setAuthFromParameter $connection)) {
            if (-not $sameResource) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "No credentials for endpoint $normalised." `
                            -ErrorId 'AzFoundryAuthMissing' -Category InvalidArgument -TargetObject $normalised `
                            -ExceptionType ([System.ArgumentException]) `
                            -RecommendedAction 'Pass -ApiKey or -UseEntraId with -Endpoint, or run Connect-AzFoundry.'))
            }
            Write-Verbose "Using the session credentials ($($session.AuthMode)) for $normalised."
            $connection.AuthMode = $session.AuthMode
            $connection.ApiKey = $session.ApiKey
        }
        return $connection
    }

    # 2. Session.
    if ($session) {
        $connection = $session.Clone()
        if (& $setAuthFromParameter $connection) {
            $connection.Source = 'Parameter'
        }
        Write-Verbose "Using the session connection to $connection."
        return $connection
    }

    # 3. Environment variables.
    $envEndpoint = [System.Environment]::GetEnvironmentVariable($endpointVar)
    if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
        $normalised = ConvertTo-AzFoundryEndpoint -Endpoint $envEndpoint
        $connection = [AzFoundryConnection]::new($normalised, 'ApiKey')
        $connection.Source = 'Environment'

        if (-not (& $setAuthFromParameter $connection)) {
            $envKey = [System.Environment]::GetEnvironmentVariable($keyVar)
            if ([string]::IsNullOrEmpty($envKey)) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "$endpointVar is set but $keyVar is not." `
                            -ErrorId 'AzFoundryAuthMissing' -Category InvalidArgument -TargetObject $keyVar `
                            -ExceptionType ([System.ArgumentException]) `
                            -RecommendedAction "Set $keyVar, pass -ApiKey or -UseEntraId, or run Connect-AzFoundry."))
            }
            $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $envKey
            $envKey = $null
        }
        Write-Verbose "No session: using $normalised from $endpointVar ($($connection.AuthMode))."
        return $connection
    }

    $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                -Message 'Not connected to an Azure AI Foundry resource.' `
                -ErrorId 'AzFoundryNotConnected' -Category InvalidOperation `
                -ExceptionType ([System.InvalidOperationException]) `
                -RecommendedAction ("Run Connect-AzFoundry, pass -Endpoint with -ApiKey or -UseEntraId, or set the " +
                "$endpointVar and $keyVar environment variables.")))
}
