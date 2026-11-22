<#
.SYNOPSIS
    Article step 9: delete the deployment created in step 8 and drop the secrets from the session.
.DESCRIPTION
    Needs 08-deploy.ps1. Deleting a deployment that no longer exists is not an error (ARM answers 204).
#>
Invoke-RestMethod -Method Delete -Uri $deploymentUri -Authentication Bearer -Token $armToken

# Dispose() zeroes the SecureString memory; Remove-Variable only drops the names
$apiKey.Dispose(); $armToken.Dispose()
Remove-Variable apiKey, armToken
