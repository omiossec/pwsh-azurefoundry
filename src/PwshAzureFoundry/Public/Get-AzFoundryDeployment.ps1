#Requires -Version 7.4

function Get-AzFoundryDeployment {
    <#
    .SYNOPSIS
        Lists the models deployed on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls GET .../accounts/{account}/deployments on Azure Resource Manager (needs Az.Accounts and
        Connect-AzAccount), or GET .../deployments/{name} when -Name has no wildcard.

        Output: PwshAzureFoundry.Deployment objects (Name, ModelName, Version, Format, Sku, Capacity,
        ProvisioningState, RaiPolicy, CreatedAt...). The deployment Name is what the inference cmdlets take as
        -Model, and the objects pipe into Invoke-AzFoundryChat and Remove-AzFoundryDeployment.
    .PARAMETER Name
        Deployment name; wildcards allowed. Without a wildcard, a missing deployment is an error.
    .PARAMETER ResourceGroupName
        Resource group of the resource. Defaults to the resource of Connect-AzFoundry -ResourceGroupName.
    .PARAMETER AccountName
        Name of the resource. Defaults to the resource of Connect-AzFoundry -AccountName.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the session, then to the current Az context.
    .EXAMPLE
        Get-AzFoundryDeployment -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry'

        Lists the deployments of the resource.
    .EXAMPLE
        Get-AzFoundryDeployment -Name 'Mistral*' | Invoke-AzFoundryChat -Prompt 'Say hello.'

        Sends the prompt to every matching deployment (needs a data-plane connection, Connect-AzFoundry).
    .LINK
        Get-AzFoundryModel
    .LINK
        New-AzFoundryDeployment
    .LINK
        Remove-AzFoundryDeployment
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Deployment')]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [ValidatePattern('^(?!\.+$)')]   # '.' or '..' would become a dot segment in the ARM path
        [SupportsWildcards()]
        [string]$Name,

        [ValidatePattern('^[-\w.()]{0,89}[-\w()]$')]
        [string]$ResourceGroupName,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId
    )

    try {
        $target = Resolve-AzFoundryArmTarget -ResourceGroupName $ResourceGroupName -AccountName $AccountName `
            -SubscriptionId $SubscriptionId
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    if ($Name -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        try {
            Invoke-AzFoundryArmRequest -Path ('{0}/deployments/{1}' -f $target.Path, [uri]::EscapeDataString($Name)) |
                ConvertTo-AzFoundryDeployment -Target $target
        } catch {
            if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
                $PSCmdlet.WriteError((New-AzFoundryErrorRecord `
                            -Message "No deployment '$Name' on $($target.AccountName)." `
                            -ErrorId 'AzFoundryDeploymentNotFound' -Category ObjectNotFound -TargetObject $Name `
                            -ExceptionType ([System.Management.Automation.ItemNotFoundException]) `
                            -RecommendedAction 'Run Get-AzFoundryDeployment without -Name to list the deployments.'))
                return
            }
            $PSCmdlet.ThrowTerminatingError($_)
        }
        return
    }

    try {
        $deployments = @(Invoke-AzFoundryArmRequest -Path "$($target.Path)/deployments" |
                ConvertTo-AzFoundryDeployment -Target $target)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
    Write-Verbose "$($deployments.Count) deployment(s) on $($target.AccountName)."
    $deployments | Where-Object { -not $Name -or $_.Name -like $Name } | Sort-Object -Property Name
}
