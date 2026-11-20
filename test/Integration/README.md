# Integration tests

Run the module against a real Azure AI Foundry resource. They are tagged `Integration`, and neither the build nor
CI runs them. Run them by hand before each release and commit the summary they write to `results/`.

| File | Scenario | Creates |
|---|---|---|
| `DataPlane.Integration.Tests.ps1` | Key, environment and Entra ID connections; chat, conversation, `-Raw`; streaming and early stop; tool calling (required, forced function, round trip, streamed); decision (brief, three types, pipeline, 422); error mapping | nothing |
| `Management.Integration.Tests.ps1` | ARM connection; catalogue; deployments; endpoint and keys; deploy an embedding model, wait for readiness, embed, duplicate refused, delete; optional partner (async) deployment | `pwshit-*` deployments, always deleted |

## Settings

| Variable | Needed for | Default |
|---|---|---|
| `AZURE_FOUNDRY_ENDPOINT` | data plane | – |
| `AZURE_FOUNDRY_API_KEY` | data plane (key) | – |
| `AZURE_FOUNDRY_RG`, `AZURE_FOUNDRY_ACCOUNT` | management plane | – |
| `AZURE_FOUNDRY_SUBSCRIPTION_ID` | management plane | subscription of the Az context |
| `AZURE_FOUNDRY_CHAT_MODEL` | chat, streaming, tools | `Mistral-Large-3` |
| `AZURE_FOUNDRY_DECISION_MODEL` | decision | `Decision-1.1` |
| `AZURE_FOUNDRY_EMBEDDING_MODEL` | catalogue model deployed for the embedding tests | `text-embedding-3-small` |
| `AZURE_FOUNDRY_ASYNC_MODEL` | optional partner deployment test (about 2 min) | not run |

A test block whose settings are missing is skipped, not failed. The Entra ID and management blocks also need
`Connect-AzAccount` (Az.Accounts); the management block needs the Cognitive Services Contributor role, and Entra
ID inference needs Cognitive Services User.

## Run

```powershell
Connect-AzAccount
$env:AZURE_FOUNDRY_ENDPOINT = 'https://<resource>.services.ai.azure.com'
$env:AZURE_FOUNDRY_API_KEY  = Read-Host 'Key' -MaskInput
$env:AZURE_FOUNDRY_RG       = '<resource-group>'
$env:AZURE_FOUNDRY_ACCOUNT  = '<resource>'
./test/Integration/Invoke-IntegrationTest.ps1
```

The run takes a few minutes and uses a few thousand tokens. It writes `results/<timestamp>.md`, a sanitised
summary with the endpoint, account, resource group, GUIDs and key replaced, and `results/<timestamp>.xml`, which is
git-ignored. Add your observations under **Notes** in the summary, then commit it.

## Cleanup

Deployments are named `pwshit-<purpose>-<UTC timestamp>` and deleted in `AfterAll`, even when a test fails. At the
end, a warning lists any `pwshit-*` deployment still on the resource, for example from an interrupted run. Delete
those with:

```powershell
Get-AzFoundryDeployment -ResourceGroupName <rg> -AccountName <resource> -Name 'pwshit-*' |
    Remove-AzFoundryDeployment -Confirm:$false
```
