#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry, Az.Accounts
<#
.SYNOPSIS
    Deploys a model from the catalogue, calls it, and deletes the deployment.
.DESCRIPTION
    Management plane: needs Az.Accounts, Connect-AzAccount and the Cognitive Services Contributor role.
    Connect-AzFoundry -ResourceGroupName -AccountName reads the endpoint and the key from the resource, so no
    key is copied by hand. New-AzFoundryDeployment waits until the deployment answers on the data plane.

    The deployment is deleted at the end, even when the call fails.
.PARAMETER ResourceGroupName
    Resource group of the Foundry resource.
.PARAMETER AccountName
    Name of the Foundry resource.
.PARAMETER ModelName
    Catalogue model to deploy (see Get-AzFoundryModel). An embedding model is quick to deploy.
.PARAMETER DeploymentName
    Name of the temporary deployment.
.EXAMPLE
    Connect-AzAccount
    ./samples/deploy-and-call.ps1 -ResourceGroupName rg-lab -AccountName <resource> -WhatIf
.EXAMPLE
    ./samples/deploy-and-call.ps1 -ResourceGroupName rg-lab -AccountName <resource>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $AccountName,

    [string] $ModelName = 'text-embedding-3-small',

    [string] $DeploymentName = 'sample-embedding'
)

$ErrorActionPreference = 'Stop'

# Connect even under -WhatIf: only the deployment is simulated
Connect-AzFoundry -ResourceGroupName $ResourceGroupName -AccountName $AccountName -WhatIf:$false

Get-AzFoundryModel -Name $ModelName
Get-AzFoundryDeployment

$deployment = Get-AzFoundryModel -Name $ModelName |
    New-AzFoundryDeployment -Name $DeploymentName -Capacity 5 -WhatIf:$WhatIfPreference
if (-not $deployment) { return }   # -WhatIf

try {
    $deployment
    Invoke-AzFoundryEmbedding -Model $DeploymentName -InputText 'Hello from PowerShell' |
        Select-Object Index, Dimensions, Text
} finally {
    Remove-AzFoundryDeployment -Name $DeploymentName -Confirm:$false
}
