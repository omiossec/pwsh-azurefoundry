#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry, Az.Accounts
<#
.SYNOPSIS
    Deploys a model from the catalogue, calls it, and deletes the deployment.
.DESCRIPTION
    Management plane: needs Az.Accounts, Connect-AzAccount and the Cognitive Services Contributor role.
    Connect-AzFoundry -ResourceGroupName -AccountName reads the endpoint and the key from the resource, so no
    key is copied by hand. New-AzFoundryDeployment waits until the deployment answers on the data plane.

    The deployment is deleted at the end, even when the deployment or the call fails. The script refuses to
    run when a deployment with that name already exists, so it never updates or deletes one it did not create.
.PARAMETER ResourceGroupName
    Resource group of the Foundry resource.
.PARAMETER AccountName
    Name of the Foundry resource.
.PARAMETER ModelName
    Catalogue model to deploy (see Get-AzFoundryModel). An embedding model is quick to deploy.
.PARAMETER DeploymentName
    Name of the temporary deployment. Must start with 'sample-' and must not exist yet.
.EXAMPLE
    Connect-AzAccount
    ./samples/deploy-and-call.ps1 -ResourceGroupName rg-lab -AccountName <resource> -WhatIf
.EXAMPLE
    ./samples/deploy-and-call.ps1 -ResourceGroupName rg-lab -AccountName <resource>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AccountName,

    [ValidateNotNullOrEmpty()]
    [string] $ModelName = 'text-embedding-3-small',

    [ValidatePattern('^sample-[a-zA-Z0-9-]+$')]
    [string] $DeploymentName = 'sample-embedding'
)

$ErrorActionPreference = 'Stop'

# Connect even under -WhatIf: only the deployment is simulated
Connect-AzFoundry -ResourceGroupName $ResourceGroupName -AccountName $AccountName -WhatIf:$false

Get-AzFoundryModel -Name $ModelName
$existing = Get-AzFoundryDeployment
$existing

# Never touch a deployment this script did not create: the finally block deletes it without a prompt
if ($existing | Where-Object Name -EQ $DeploymentName) {
    throw "A deployment named '$DeploymentName' already exists. Pass another -DeploymentName."
}
if ($WhatIfPreference) {
    Get-AzFoundryModel -Name $ModelName | New-AzFoundryDeployment -Name $DeploymentName -Capacity 5 -WhatIf
    return
}

try {
    Get-AzFoundryModel -Name $ModelName | New-AzFoundryDeployment -Name $DeploymentName -Capacity 5
    Invoke-AzFoundryEmbedding -Model $DeploymentName -InputText 'Hello from PowerShell' |
        Select-Object Index, Dimensions, Text
} finally {
    # Runs even when New-AzFoundryDeployment fails after the PUT (for example, the readiness probe times out)
    Remove-AzFoundryDeployment -Name $DeploymentName -Confirm:$false -ErrorAction Continue
}
