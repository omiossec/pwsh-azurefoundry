#Requires -Version 7.4

function Get-AzFoundryAccessToken {
    <#
    .SYNOPSIS
        Returns a cached Entra ID access token for a resource.
    .DESCRIPTION
        Gets tokens from Az.Accounts (Get-AzAccessToken) and caches them in memory per resource, account and
        tenant. A cached token is reused until 5 minutes before it expires. The token is always returned as a
        SecureString, whether Az.Accounts returns a string (2.x) or a SecureString (newer versions).

        Used for data-plane calls with -UseEntraId (resource https://cognitiveservices.azure.com) and for
        every ARM call (resource https://management.azure.com).
    .PARAMETER ResourceUrl
        Resource the token is for, for example https://management.azure.com.
    .PARAMETER ForceRefresh
        Ignore the cache and get a new token.
    .EXAMPLE
        $token = Get-AzFoundryAccessToken -ResourceUrl $script:AzFoundryArmBaseUri
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceUrl,

        [switch]$ForceRefresh
    )

    Import-AzFoundryAzAccounts

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Account) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message 'No Azure sign-in found in this session.' `
                    -ErrorId 'AzFoundryAzContextMissing' -Category AuthenticationError -TargetObject $ResourceUrl `
                    -ExceptionType ([System.UnauthorizedAccessException]) `
                    -RecommendedAction 'Run Connect-AzAccount (Entra ID auth and the management cmdlets need it).'))
    }

    $resource = $ResourceUrl.TrimEnd('/')
    $cacheKey = '{0}|{1}|{2}' -f $resource, $context.Account.Id, $context.Tenant.Id
    $cached = $script:AzFoundryTokenCache[$cacheKey]
    if (-not $ForceRefresh -and $cached -and $cached.ExpiresOn -gt [datetimeoffset]::UtcNow.AddMinutes(5)) {
        Write-Debug "Using the cached Entra ID token for $resource (expires $($cached.ExpiresOn.ToString('u')))."
        return $cached
    }

    $tokenParameters = @{
        ResourceUrl   = $resource
        ErrorAction   = 'Stop'
        WarningAction = 'SilentlyContinue'
    }
    $tokenCommand = Get-Command -Name 'Get-AzAccessToken' -ErrorAction SilentlyContinue
    if ($tokenCommand -and $tokenCommand.Parameters.ContainsKey('AsSecureString')) {
        $tokenParameters['AsSecureString'] = $true
    }

    Write-Verbose "Getting an Entra ID token for $resource."
    try {
        $result = Get-AzAccessToken @tokenParameters
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Could not get an Entra ID token for $($resource): $($_.Exception.Message)" `
                    -ErrorId 'AzFoundryTokenFailed' -Category AuthenticationError -TargetObject $resource `
                    -InnerException $_.Exception `
                    -RecommendedAction 'Run Connect-AzAccount and check the account can access the resource.'))
    }

    $token = if ($result.Token -is [securestring]) {
        $result.Token
    } else {
        ConvertTo-AzFoundrySecureString -String ([string]$result.Token)
    }

    $entry = [pscustomobject]@{
        Token     = $token
        ExpiresOn = [datetimeoffset]$result.ExpiresOn
    }
    $script:AzFoundryTokenCache[$cacheKey] = $entry
    $entry
}
