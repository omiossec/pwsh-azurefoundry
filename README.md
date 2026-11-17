# pwsh-azurefoundry

**PwshAzureFoundry** is a PowerShell module for models deployed on an
[Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/) resource. With it you can call
models (LLM chat, embeddings, decision models), list available and deployed models, deploy and
remove models, and get the endpoint URI and keys, all from PowerShell, without `curl` or the `az` CLI.

> **Status: design phase.** No code has been released yet. The cmdlets below are the planned v0.1
> surface and may change.

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 7.4 or later |
| Az.Accounts | only for management cmdlets and Entra ID auth |
| Pester *(tests)* | 5.x |
| PSScriptAnalyzer *(build)* | latest |

## Planned usage

```powershell
Import-Module PwshAzureFoundry

# Connect with an API key (or -UseEntraId, or -ResourceGroupName/-AccountName to resolve via ARM)
$key = Read-Host -AsSecureString 'API key'
Connect-AzFoundry -Endpoint 'https://<resource>.services.ai.azure.com' -ApiKey $key

# LLM chat
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'I am going to Paris, what should I see?'

# Streaming
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Tell me a story' -Stream

# Decision model
Invoke-AzFoundryDecision -Model 'Decision-1.1' `
    -State 'The payment integration still fails. Please help today.' `
    -Predicate @{ urgent = 'Does this message convey urgency?' }

# Models and deployments (Az.Accounts)
Get-AzFoundryModel      -ResourceGroupName rg-lab -AccountName <resource>
Get-AzFoundryDeployment -ResourceGroupName rg-lab -AccountName <resource>
New-AzFoundryDeployment -ResourceGroupName rg-lab -AccountName <resource> -Name 'Mistral-Large-3' -ModelName 'Mistral-Large-3'
Get-AzFoundryEndpoint   -ResourceGroupName rg-lab -AccountName <resource>
```

## Planned cmdlets

| Area | Cmdlets |
|---|---|
| Connection | `Connect-AzFoundry`, `Get-AzFoundryConnection`, `Disconnect-AzFoundry` |
| Inference | `New-AzFoundryMessage`, `Invoke-AzFoundryChat`, `Invoke-AzFoundryEmbedding`, `Invoke-AzFoundryDecision` |
| Management | `Get-AzFoundryModel`, `Get-AzFoundryDeployment`, `New-AzFoundryDeployment`, `Remove-AzFoundryDeployment`, `Get-AzFoundryEndpoint` |

## Repository layout

| Folder | Content |
|---|---|
| `src/` | Module sources (`src/PwshAzureFoundry`) |
| `test/` | Pester unit tests, fixtures, integration tests |
| `docs/` | Cmdlet reference and guides |
| `samples/` | Example scripts |

## Related

- [PwshFoundry](https://github.com/omiossec/pwsh-foundry): the sister module for **Foundry Local**.

## License

See [LICENSE](LICENSE).
