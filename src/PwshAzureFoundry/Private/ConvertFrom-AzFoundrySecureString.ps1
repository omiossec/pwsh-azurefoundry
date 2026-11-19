#Requires -Version 7.4

function ConvertFrom-AzFoundrySecureString {
    <#
    .SYNOPSIS
        Returns the plain text of a SecureString.
    .DESCRIPTION
        The only place in the module where a secret (API key or Entra token) is unwrapped. Callers use the
        result right away to build an HTTP header and never log it, store it or put it in an error.
    .PARAMETER SecureString
        The secret to unwrap.
    .EXAMPLE
        $headers = @{ 'api-key' = ConvertFrom-AzFoundrySecureString -SecureString $connection.ApiKey }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [securestring]$SecureString
    )

    [System.Net.NetworkCredential]::new('', $SecureString).Password
}
