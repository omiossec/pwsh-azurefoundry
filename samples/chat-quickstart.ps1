#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry
<#
.SYNOPSIS
    Connects to a Foundry resource with an API key and asks one question to a chat deployment.
.DESCRIPTION
    Key-based: needs only PwshAzureFoundry (no Az.Accounts). The key is read as a SecureString and never
    shown. Then runs a single prompt and a short conversation (the Paris example of the Foundry docs).
.PARAMETER Endpoint
    Endpoint of the resource, for example https://<resource>.services.ai.azure.com.
.PARAMETER Model
    Chat deployment name.
.EXAMPLE
    ./samples/chat-quickstart.ps1 -Endpoint https://<resource>.services.ai.azure.com -Model Mistral-Large-3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Endpoint,

    [string] $Model = 'Mistral-Large-3'
)

$ErrorActionPreference = 'Stop'

$key = Read-Host -AsSecureString -Prompt 'API key'
Connect-AzFoundry -Endpoint $Endpoint -ApiKey $key
Get-AzFoundryConnection

# One prompt
Invoke-AzFoundryChat -Model $Model -Prompt 'In one sentence, what is Azure AI Foundry?' -MaxTokens 200

# A conversation: append each answer (ChatResult.Message) to the history
$history = [System.Collections.Generic.List[object]]::new()
$history.Add((New-AzFoundryMessage -Role user -Content 'I am going to Paris, what should I see?'))
$result = Invoke-AzFoundryChat -Model $Model -Message $history -MaxTokens 400
$history.Add($result.Message)
$history.Add((New-AzFoundryMessage -Role user -Content 'What is so great about #1?'))
$result = Invoke-AzFoundryChat -Model $Model -Message $history -MaxTokens 400 -Temperature 0.8 -TopP 0.1
$result.Content
