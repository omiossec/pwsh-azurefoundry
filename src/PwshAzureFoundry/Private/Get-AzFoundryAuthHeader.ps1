#Requires -Version 7.4

function Get-AzFoundryAuthHeader {
    <#
    .SYNOPSIS
        Builds the authentication header of a data-plane request.
    .DESCRIPTION
        ApiKey connections send 'api-key: <key>'. EntraId connections send 'Authorization: Bearer <token>',
        with a token for $script:AzFoundryTokenScope taken from the module token cache. Keeping the two
        headers separate makes debug output unambiguous (spec section 4.1).

        The returned hashtable holds a plain-text secret: pass it straight to the HTTP helper and never log it.
    .PARAMETER Connection
        The resolved connection.
    .EXAMPLE
        $headers = Get-AzFoundryAuthHeader -Connection $connection
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AzFoundryConnection]$Connection
    )

    switch ($Connection.AuthMode) {
        'ApiKey' {
            if (-not $Connection.ApiKey) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "The connection to $($Connection.Endpoint) has no API key." `
                            -ErrorId 'AzFoundryAuthMissing' -Category AuthenticationError `
                            -TargetObject $Connection.Endpoint -ExceptionType ([System.InvalidOperationException]) `
                            -RecommendedAction 'Run Connect-AzFoundry with -ApiKey, or use -UseEntraId.'))
            }
            return @{ 'api-key' = ConvertFrom-AzFoundrySecureString -SecureString $Connection.ApiKey }
        }
        'EntraId' {
            $resource = $script:AzFoundryTokenScope -replace '/\.default$', ''
            $token = Get-AzFoundryAccessToken -ResourceUrl $resource
            return @{ Authorization = 'Bearer ' + (ConvertFrom-AzFoundrySecureString -SecureString $token.Token) }
        }
        default {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "Unknown authentication mode '$($Connection.AuthMode)'." `
                        -ErrorId 'AzFoundryAuthModeUnknown' -Category InvalidArgument `
                        -ExceptionType ([System.ArgumentException])))
        }
    }
}
