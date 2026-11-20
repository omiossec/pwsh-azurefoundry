#Requires -Version 7.4

function ConvertTo-AzFoundryDateTimeOffset {
    <#
    .SYNOPSIS
        Converts an ARM date (ISO 8601 string, or the DateTime ConvertFrom-Json makes of it) to a UTC
        DateTimeOffset.
    .DESCRIPTION
        Returns nothing for $null, an empty string or a value that is not a date. A string without an offset is
        read as UTC.
    .PARAMETER Value
        The date.
    .EXAMPLE
        ConvertTo-AzFoundryDateTimeOffset -Value $systemData.createdAt
    #>
    [CmdletBinding()]
    [OutputType([datetimeoffset])]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [datetime]) {
        $utc = if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        } else {
            $Value.ToUniversalTime()
        }
        return [datetimeoffset]::new($utc)
    }
    $parsed = [datetimeoffset]::MinValue
    if ($Value -and [datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
}
