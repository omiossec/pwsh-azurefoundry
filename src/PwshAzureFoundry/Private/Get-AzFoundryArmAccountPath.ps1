#Requires -Version 7.4

function Get-AzFoundryArmAccountPath {
    <#
    .SYNOPSIS
        Returns the ARM path of a Foundry resource (Microsoft.CognitiveServices account).
    .DESCRIPTION
        Builds /subscriptions/{s}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{a}, with each
        name escaped, for Invoke-AzFoundryArmRequest.
    .PARAMETER SubscriptionId
        Subscription id.
    .PARAMETER ResourceGroupName
        Resource group name.
    .PARAMETER AccountName
        Resource (account) name.
    .EXAMPLE
        Get-AzFoundryArmAccountPath -SubscriptionId $sub -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$AccountName
    )

    '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.CognitiveServices/accounts/{2}' -f @(
        [uri]::EscapeDataString($SubscriptionId),
        [uri]::EscapeDataString($ResourceGroupName),
        [uri]::EscapeDataString($AccountName)
    )
}
