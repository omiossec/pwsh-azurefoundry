#Requires -Version 7.4

function ConvertTo-AzFoundrySecureString {
    <#
    .SYNOPSIS
        Wraps a plain-text secret in a read-only SecureString.
    .DESCRIPTION
        Used as soon as a secret is read in plain text (AZURE_FOUNDRY_API_KEY, an Entra token returned as a
        string by older Az.Accounts versions, ARM listKeys), so the module only keeps SecureStrings.
    .PARAMETER String
        The plain-text secret.
    .EXAMPLE
        $key = ConvertTo-AzFoundrySecureString -String $env:AZURE_FOUNDRY_API_KEY
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$String
    )

    $secure = [securestring]::new()
    foreach ($character in $String.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    $secure
}
