#Requires -Version 7.4

function Resolve-AzFoundryArmTarget {
    <#
    .SYNOPSIS
        Returns the Foundry resource a management cmdlet works on.
    .DESCRIPTION
        Uses -ResourceGroupName and -AccountName when both are given (the subscription comes from -SubscriptionId
        or the current Az context). With neither, uses the session connection when it was made with
        Connect-AzFoundry -ResourceGroupName ... -AccountName ... (spec section 5.3). Anything else is a
        terminating error (AzFoundryArmTargetMissing).

        Output: { SubscriptionId, ResourceGroupName, AccountName, Path } where Path is the ARM path of the
        account (Get-AzFoundryArmAccountPath).
    .PARAMETER ResourceGroupName
        Resource group of the resource.
    .PARAMETER AccountName
        Name of the resource.
    .PARAMETER SubscriptionId
        Subscription of the resource.
    .EXAMPLE
        $target = Resolve-AzFoundryArmTarget -ResourceGroupName $ResourceGroupName -AccountName $AccountName
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ResourceGroupName,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$AccountName,

        [AllowEmptyString()]
        [AllowNull()]
        [string]$SubscriptionId
    )

    $hasGroup = -not [string]::IsNullOrWhiteSpace($ResourceGroupName)
    $hasAccount = -not [string]::IsNullOrWhiteSpace($AccountName)
    $hint = 'Pass -ResourceGroupName and -AccountName, or run Connect-AzFoundry -ResourceGroupName ... -AccountName ...'

    if ($hasGroup -ne $hasAccount) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message '-ResourceGroupName and -AccountName go together.' `
                    -ErrorId 'AzFoundryArmTargetMissing' -Category InvalidArgument `
                    -ExceptionType ([System.ArgumentException]) -RecommendedAction $hint))
    }

    if (-not $hasGroup) {
        $session = $script:AzFoundryConnection
        if (-not $session -or [string]::IsNullOrWhiteSpace($session.ResourceGroupName) -or
            [string]::IsNullOrWhiteSpace($session.AccountName)) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message 'No Foundry resource given, and the session does not name one.' `
                        -ErrorId 'AzFoundryArmTargetMissing' -Category InvalidArgument `
                        -ExceptionType ([System.ArgumentException]) -RecommendedAction $hint))
        }
        $ResourceGroupName = $session.ResourceGroupName
        $AccountName = $session.AccountName
        if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
            $SubscriptionId = $session.SubscriptionId
        }
        Write-Verbose "Using the resource of the session: $AccountName (resource group $ResourceGroupName)."
    }

    $subscription = Resolve-AzFoundrySubscriptionId -SubscriptionId $SubscriptionId
    [pscustomobject]@{
        SubscriptionId    = $subscription
        ResourceGroupName = $ResourceGroupName
        AccountName       = $AccountName
        Path              = Get-AzFoundryArmAccountPath -SubscriptionId $subscription `
            -ResourceGroupName $ResourceGroupName -AccountName $AccountName
    }
}
