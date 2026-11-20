#Requires -Version 7.4

function Resolve-AzFoundrySubscriptionId {
    <#
    .SYNOPSIS
        Returns the subscription id for a management call.
    .DESCRIPTION
        Returns -SubscriptionId when it is given, otherwise the subscription of the current Az context
        (spec section 4.2). Loads Az.Accounts. Throws when there is no context or no subscription.
    .PARAMETER SubscriptionId
        Explicit subscription id.
    .EXAMPLE
        $subscription = Resolve-AzFoundrySubscriptionId -SubscriptionId $SubscriptionId
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SubscriptionId
    )

    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        return $SubscriptionId
    }

    Import-AzFoundryAzAccounts
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Account) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message 'No Azure sign-in found in this session.' `
                    -ErrorId 'AzFoundryAzContextMissing' -Category AuthenticationError `
                    -ExceptionType ([System.UnauthorizedAccessException]) `
                    -RecommendedAction 'Run Connect-AzAccount (the management cmdlets need it).'))
    }
    if (-not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message 'The current Az context has no subscription.' `
                    -ErrorId 'AzFoundrySubscriptionMissing' -Category InvalidArgument `
                    -ExceptionType ([System.ArgumentException]) `
                    -RecommendedAction 'Pass -SubscriptionId, or run Set-AzContext -Subscription <id>.'))
    }
    Write-Verbose "Using the subscription of the current Az context ($($context.Subscription.Id))."
    [string]$context.Subscription.Id
}
