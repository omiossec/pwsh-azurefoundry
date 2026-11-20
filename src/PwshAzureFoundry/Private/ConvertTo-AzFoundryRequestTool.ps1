#Requires -Version 7.4

function ConvertTo-AzFoundryRequestTool {
    <#
    .SYNOPSIS
        Converts the -Tool input of Invoke-AzFoundryChat to the 'tools' wire shape.
    .DESCRIPTION
        Accepts AzFoundryTool objects (New-AzFoundryTool), converted with ToHashtable(), and dictionaries
        already in the wire shape @{ type = 'function'; function = @{ name = ...; ... } }, sent as-is.
        Anything else is a terminating error (AzFoundryInvalidTool).
    .PARAMETER InputObject
        The tool definitions.
    .EXAMPLE
        $tools = @(ConvertTo-AzFoundryRequestTool -InputObject $Tool)
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$InputObject
    )

    foreach ($item in $InputObject) {
        $value = if ($item -is [psobject]) { $item.PSObject.BaseObject } else { $item }

        if ($value -is [AzFoundryTool]) {
            $value.ToHashtable()
            continue
        }
        if ($value -is [System.Collections.IDictionary] -and $value['type'] -eq 'function' -and
            $value['function'] -is [System.Collections.IDictionary] -and $value['function']['name']) {
            $value
            continue
        }

        $shown = if ($null -eq $value) { '$null' } else { $value.GetType().Name }
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Invalid tool definition ($shown)." `
                    -ErrorId 'AzFoundryInvalidTool' -Category InvalidArgument -TargetObject $shown `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction "Use New-AzFoundryTool, or @{ type = 'function'; function = @{ name = ... } }."))
    }
}
