#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry, Az.Accounts
<#
.SYNOPSIS
    The closing block of the dev.to article: samples/article/01 to 07 again, with PwshAzureFoundry.
.DESCRIPTION
    The article's last section. It runs against the module published on the PowerShell Gallery
    (Install-PSResource PwshAzureFoundry -Version 0.1.0), not the repository copy; Article.Tests.ps1 checks it.
    Needs Connect-AzAccount and the same deployments as the article.
.PARAMETER ResourceGroupName
    Resource group of the Foundry resource.
.PARAMETER AccountName
    Name of the Foundry resource.
.PARAMETER ChatModel
    Chat deployment name.
.PARAMETER DecisionModel
    Decision deployment name.
.EXAMPLE
    Install-PSResource PwshAzureFoundry -Version 0.1.0
    ./samples/article-teaser.ps1 -ResourceGroupName $env:AZURE_FOUNDRY_RG -AccountName $env:AZURE_FOUNDRY_ACCOUNT
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName = $env:AZURE_FOUNDRY_RG,

    [ValidateNotNullOrEmpty()]
    [string] $AccountName = $env:AZURE_FOUNDRY_ACCOUNT,

    [ValidateNotNullOrEmpty()]
    [string] $ChatModel = 'Mistral-Large-3',

    [ValidateNotNullOrEmpty()]
    [string] $DecisionModel = 'Decision-1.1'
)

$ErrorActionPreference = 'Stop'

# --- The article block starts here ---
# Endpoint and key, read through ARM
Connect-AzFoundry -ResourceGroupName $ResourceGroupName -AccountName $AccountName
Get-AzFoundryDeployment

Invoke-AzFoundryChat -Model $ChatModel -Prompt 'Write a haiku about PowerShell.' -Stream |
    ForEach-Object { Write-Host $_.Content -NoNewline }
Write-Host

Invoke-AzFoundryDecision -Model $DecisionModel -State 'The payment integration still fails. Please help today.' `
    -Predicate @{ urgent = 'Does this message convey urgency?' }
# --- The article block ends here ---

Disconnect-AzFoundry
