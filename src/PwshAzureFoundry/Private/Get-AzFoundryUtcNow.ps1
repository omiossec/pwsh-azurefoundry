#Requires -Version 7.4

function Get-AzFoundryUtcNow {
    <#
    .SYNOPSIS
        Returns the current UTC time.
    .DESCRIPTION
        The single place where the module reads the clock for date comparisons (model deprecation), so the
        unit tests can mock it.
    .EXAMPLE
        $now = Get-AzFoundryUtcNow
    #>
    [CmdletBinding()]
    [OutputType([datetimeoffset])]
    param()

    [datetimeoffset]::UtcNow
}
