#Requires -Version 7.4

function ConvertTo-AzFoundryLogUri {
    <#
    .SYNOPSIS
        Returns a URI that is safe to log or show in an error.
    .DESCRIPTION
        Keeps the scheme, host and path, and only the api-version query parameter. Every other query
        parameter is replaced by '<redacted>': the ARM async operation URLs carry a signature in their query
        string (spec section 4.2).
    .PARAMETER Uri
        The URI to clean.
    .EXAMPLE
        ConvertTo-AzFoundryLogUri -Uri 'https://management.azure.com/x?api-version=2025-06-01&s=abc'

        Returns https://management.azure.com/x?api-version=2025-06-01&<redacted>
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [uri]$Uri
    )

    if (-not $Uri.IsAbsoluteUri) {
        return $Uri.OriginalString
    }

    $base = $Uri.GetLeftPart([System.UriPartial]::Path)
    $query = $Uri.Query.TrimStart('?')
    if (-not $query) {
        return $base
    }

    $pairs = $query.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)
    $kept = @($pairs | Where-Object { $_ -like 'api-version=*' })
    if ($kept.Count -lt $pairs.Count) {
        $kept += '<redacted>'
    }
    '{0}?{1}' -f $base, ($kept -join '&')
}
