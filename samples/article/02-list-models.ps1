<#
.SYNOPSIS
    Article step 2: list the models you can deploy and the models already deployed, with plain REST.
.DESCRIPTION
    Needs 01-connect.ps1. Sets $deployments for the next snippets.
#>
# The catalogue of this resource: every model and version the region offers (about 190 entries)
$catalog = Invoke-RestMethod -Uri "${account}/models?api-version=$armApi" -Authentication Bearer -Token $armToken

$catalog.value |
    Where-Object { $_.capabilities.chatCompletion -eq 'true' -and $_.isDefaultVersion } |
    Where-Object lifecycleStatus -NE 'Deprecated' |
    Sort-Object format, name |
    Format-Table format, name, version, lifecycleStatus

# What is already deployed on the resource
$deployments = (Invoke-RestMethod -Uri "${account}/deployments?api-version=$armApi" `
        -Authentication Bearer -Token $armToken).value

$deployments | ForEach-Object {
    [pscustomobject]@{
        Name     = $_.name
        Model    = $_.properties.model.name
        Sku      = $_.sku.name
        Capacity = $_.sku.capacity
        State    = $_.properties.provisioningState
    }
} | Format-Table
