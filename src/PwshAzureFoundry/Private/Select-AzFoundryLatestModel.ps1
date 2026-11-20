#Requires -Version 7.4

function Select-AzFoundryLatestModel {
    <#
    .SYNOPSIS
        Keeps one version per model: the default version, or else the highest one.
    .DESCRIPTION
        Groups PwshAzureFoundry.Model objects by Format and Name (case-insensitive). In each group, returns the
        version flagged IsDefaultVersion, or, when none (or several) are flagged, the highest version. Versions
        compare with their digit runs as numbers, so '10' > '9', '001' = '1' and dates (2025-12-08) sort in time
        order. Groups come out in the order they first appear.
    .PARAMETER InputObject
        PwshAzureFoundry.Model objects.
    .EXAMPLE
        $models | Select-AzFoundryLatestModel
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Model')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject
    )

    begin {
        $groups = [ordered]@{}
    }

    process {
        if ($null -eq $InputObject) {
            return
        }
        $key = ('{0}|{1}' -f $InputObject.Format, $InputObject.Name).ToLowerInvariant()
        if (-not $groups.Contains($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$key].Add($InputObject)
    }

    end {
        $versionKey = {
            (([string]$_.Version -split '(\d+)') | ForEach-Object {
                if ($_ -match '^\d+$') { $_.TrimStart('0').PadLeft(20, '0') } else { $_.ToLowerInvariant() }
            }) -join ''
        }
        foreach ($group in $groups.Values) {
            $defaults = @($group | Where-Object IsDefaultVersion)
            if ($defaults.Count -eq 1) {
                $defaults[0]
            } else {
                $group | Sort-Object -Property $versionKey -Descending | Select-Object -First 1
            }
        }
    }
}
