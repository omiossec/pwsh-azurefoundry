<#
.SYNOPSIS
    Article step 1: sign in to Azure and read the endpoint and key of a Foundry resource, with plain REST.
.DESCRIPTION
    Uses Az.Accounts and Invoke-RestMethod only (no PwshAzureFoundry). Sets $account (ARM path of the
    resource), $armToken, $armApi, $endpoint and $apiKey for the next snippets.
#>
$resourceGroup = $env:AZURE_FOUNDRY_RG        # for example 'rg-foundry-demo'
$accountName   = $env:AZURE_FOUNDRY_ACCOUNT   # the name of the Foundry resource

if (-not (Get-AzContext)) { Connect-AzAccount }
$subscriptionId = (Get-AzContext).Subscription.Id

# Az.Accounts 5 returns the token as a SecureString, older versions as a plain string
$armToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
if ($armToken -isnot [securestring]) { $armToken = ConvertTo-SecureString $armToken -AsPlainText -Force }

$armApi  = '2025-06-01'
$group   = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$account = "$group/providers/Microsoft.CognitiveServices/accounts/$accountName"

# ${account} and not $account: in PowerShell 7, "$account?api-version" reads a variable named 'account?'
$resource = Invoke-RestMethod -Uri "${account}?api-version=$armApi" -Authentication Bearer -Token $armToken
$endpoint = $resource.properties.endpoints.'AI Foundry API'.TrimEnd('/')

$keys = Invoke-RestMethod -Method Post -Uri "${account}/listKeys?api-version=$armApi" `
    -Authentication Bearer -Token $armToken
$apiKey = ConvertTo-SecureString $keys.key1 -AsPlainText -Force
Remove-Variable keys

"Endpoint: $endpoint"
