#Requires -Version 7.4

function Remove-AzFoundryDeployment {
    <#
    .SYNOPSIS
        Deletes a model deployment from an Azure AI Foundry resource.
    .DESCRIPTION
        Calls DELETE .../accounts/{account}/deployments/{name} on Azure Resource Manager (needs Az.Accounts and
        Connect-AzAccount). OpenAI deployments are deleted at once; partner deployments take about 30 s, and the
        cmdlet waits for them unless -NoWait is given.

        Asks for confirmation (ConfirmImpact High): add -Confirm:$false in scripts. Accepts pipeline input from
        Get-AzFoundryDeployment (Name, ResourceGroupName, AccountName and SubscriptionId bind by property name).

        Output: nothing.
    .PARAMETER Name
        Deployment name.
    .PARAMETER NoWait
        Return as soon as ARM accepts the deletion.
    .PARAMETER ResourceGroupName
        Resource group of the resource. Defaults to the resource of Connect-AzFoundry -ResourceGroupName.
    .PARAMETER AccountName
        Name of the resource. Defaults to the resource of Connect-AzFoundry -AccountName.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the session, then to the current Az context.
    .EXAMPLE
        Remove-AzFoundryDeployment -Name 'text-embedding-3-small' -WhatIf

        Shows what would be deleted.
    .EXAMPLE
        Get-AzFoundryDeployment -Name 'test-*' | Remove-AzFoundryDeployment -Confirm:$false

        Deletes every deployment whose name starts with test-, without asking.
    .LINK
        Get-AzFoundryDeployment
    .LINK
        New-AzFoundryDeployment
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$Name,

        [switch]$NoWait,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[-\w.()]{1,90}$')]
        [string]$ResourceGroupName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId
    )

    process {
        try {
            $target = Resolve-AzFoundryArmTarget -ResourceGroupName $ResourceGroupName -AccountName $AccountName `
                -SubscriptionId $SubscriptionId
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        if (-not $PSCmdlet.ShouldProcess("$Name on $($target.AccountName)", 'Delete the deployment')) {
            return
        }

        Write-Verbose "Deleting $Name on $($target.AccountName)."
        try {
            $null = Invoke-AzFoundryArmRequest -Method DELETE -NoWait:$NoWait `
                -Path ('{0}/deployments/{1}' -f $target.Path, [uri]::EscapeDataString($Name))
        } catch {
            # One failed item must not stop the rest of the pipeline.
            $PSCmdlet.WriteError($_)
            return
        }
        Write-Verbose $(if ($NoWait) { "Deletion of $Name accepted (-NoWait)." } else { "$Name deleted." })
    }
}
