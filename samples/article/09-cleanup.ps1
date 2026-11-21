<#
.SYNOPSIS
    Article step 9: delete the deployment created in step 8 and forget the secrets.
.DESCRIPTION
    Needs 08-deploy.ps1. Deleting a deployment that no longer exists is not an error (ARM answers 204).
#>
Invoke-RestMethod -Method Delete -Uri $deploymentUri -Authentication Bearer -Token $armToken

Remove-Variable apiKey, armToken
