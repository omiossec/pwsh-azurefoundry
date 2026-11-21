<#
.SYNOPSIS
    Article step 3: pick a chat deployment and a decision deployment from the list.
.DESCRIPTION
    Needs 02-list-models.ps1. Sets $chatModel and $decisionModel (deployment names, which the data plane
    takes as 'model').
#>
# Capabilities are strings ('true'/'false'), not booleans
$chatModel = $deployments |
    Where-Object { $_.properties.capabilities.chatCompletion -eq 'true' } |
    Select-Object -First 1 -ExpandProperty name

$decisionModel = $deployments |
    Where-Object { $_.properties.capabilities.decision -eq 'true' } |
    Select-Object -First 1 -ExpandProperty name

# Interactive alternative: $chatModel = ($deployments | Out-GridView -PassThru).name

if (-not $chatModel -or -not $decisionModel) { throw 'Deploy a chat model and a decision model first.' }
"Chat: $chatModel   Decision: $decisionModel"
