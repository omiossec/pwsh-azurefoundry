#Requires -Version 7.4

function ConvertFrom-AzFoundryJsonContent {
    <#
    .SYNOPSIS
        Parses a JSON response body.
    .DESCRIPTION
        Returns $null for an empty body, the parsed object for JSON, and the raw text (with a debug message)
        when the body is not JSON.
    .PARAMETER Content
        Response body.
    .EXAMPLE
        ConvertFrom-AzFoundryJsonContent -Content $response.Content
    #>
    [CmdletBinding()]
    [OutputType([object], [string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }
    try {
        ConvertFrom-Json -InputObject $Content -Depth 100 -ErrorAction Stop
    } catch {
        Write-Debug 'The response body is not JSON; returning it as text.'
        $Content
    }
}
