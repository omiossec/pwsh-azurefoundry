#Requires -Version 7.4

function Hide-AzFoundrySecret {
    <#
    .SYNOPSIS
        Masks secrets in a text before it is logged or put in an error message.
    .DESCRIPTION
        Replaces every occurrence of the given secret values with '***', then masks anything that looks
        like a bearer token or an api-key header value. Used on debug output and on service error
        messages, as a second line of defence: the module never puts a secret in a text on purpose.
    .PARAMETER Text
        Text to clean.
    .PARAMETER Secret
        Plain-text secret values to mask (API key, token).
    .EXAMPLE
        Write-Debug (Hide-AzFoundrySecret -Text $body -Secret $apiKey)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Secret
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $clean = $Text
    foreach ($value in $Secret) {
        if (-not [string]::IsNullOrEmpty($value)) {
            $clean = $clean.Replace($value, '***')
        }
    }

    $clean = $clean -replace '(?i)(bearer\s+)[A-Za-z0-9\-_.~+/=]{8,}', '$1***'
    $clean -replace '(?i)("?api-key"?\s*[:=]\s*"?)[A-Za-z0-9]{8,}', '$1***'
}
