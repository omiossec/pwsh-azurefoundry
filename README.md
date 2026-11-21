# pwsh-azurefoundry

**PwshAzureFoundry** is a PowerShell module for models deployed on an
[Azure AI Foundry](https://learn.microsoft.com/azure/ai-foundry/) resource. With it you can call
models (LLM chat, embeddings, decision models), list available and deployed models, deploy and
remove models, and get the endpoint URI and keys, all from PowerShell, without `curl` or the `az` CLI.

> **Status: 0.1.0**, the first stable version, on the [PowerShell Gallery](https://www.powershellgallery.com/packages/PwshAzureFoundry).
> Changes are listed in the [CHANGELOG](CHANGELOG.md).

---

## Requirements

| Requirement | Version |
|---|---|
| PowerShell | 7.4 or later (Windows, Linux, macOS) |
| Az.Accounts | 2.13.0 or later, only for management cmdlets and Entra ID auth |
| Pester *(tests)* | 5.x |
| PSScriptAnalyzer *(build)* | latest |

## Install

```powershell
# From the PowerShell Gallery
Install-PSResource PwshAzureFoundry

# From source
git clone https://github.com/omiossec/pwsh-azurefoundry
./pwsh-azurefoundry/build/build.ps1
Import-Module ./pwsh-azurefoundry/src/PwshAzureFoundry/PwshAzureFoundry.psd1
```

## Quick start

```powershell
# Connect from the resource (Az.Accounts): the endpoint and key are read for you...
Connect-AzAccount
Connect-AzFoundry -ResourceGroupName 'rg-lab' -AccountName '<resource>'

# ...or with a key only (no Az.Accounts needed)
$key = Read-Host -AsSecureString 'API key'
Connect-AzFoundry -Endpoint 'https://<resource>.services.ai.azure.com' -ApiKey $key

# Chat, and streaming
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'I am going to Paris, what should I see?'
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Tell me a story' -Stream |
    ForEach-Object { Write-Host $_.Content -NoNewline }

# Decision model
Invoke-AzFoundryDecision -Model 'Decision-1.1' `
    -State 'The payment integration still fails. Please help today.' `
    -Predicate @{ urgent = 'Does this message convey urgency?' }

# Embeddings
'first text', 'second text' | Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small'

# Models and deployments (Az.Accounts)
Get-AzFoundryModel -Format 'Mistral AI' -Task chatCompletion
Get-AzFoundryDeployment
Get-AzFoundryModel -Name 'text-embedding-3-small' | New-AzFoundryDeployment -Capacity 10
Get-AzFoundryDeployment -Name 'text-embedding-3-small' | Remove-AzFoundryDeployment -Confirm:$false
Get-AzFoundryEndpoint
```

In CI and containers, the data-plane cmdlets also read `AZURE_FOUNDRY_ENDPOINT` and `AZURE_FOUNDRY_API_KEY`
when no connection is set (order: cmdlet parameters, then `Connect-AzFoundry`, then the variables). These
variables hold the key in plain text: prefer `Connect-AzFoundry` interactively. Details, roles and
troubleshooting are in [docs/README.md](docs/README.md).

## Cmdlets

| Area | Cmdlets |
|---|---|
| Connection | `Connect-AzFoundry`, `Get-AzFoundryConnection`, `Disconnect-AzFoundry` |
| Inference | `New-AzFoundryMessage`, `New-AzFoundryTool`, `Invoke-AzFoundryChat`, `Invoke-AzFoundryEmbedding`, `Invoke-AzFoundryDecision` |
| Management | `Get-AzFoundryModel`, `Get-AzFoundryDeployment`, `New-AzFoundryDeployment`, `Remove-AzFoundryDeployment`, `Get-AzFoundryEndpoint` |

Reference: [docs/README.md](docs/README.md). Examples: [samples/](samples/README.md).

## Repository layout

| Folder | Content |
|---|---|
| `src/` | Module sources (`src/PwshAzureFoundry`) |
| `test/` | Pester unit tests, fixtures, integration tests |
| `docs/` | Cmdlet reference, authentication guide, troubleshooting |
| `samples/` | Example scripts; `samples/article/` does the same tasks with plain REST |

## Related

- [PwshFoundry](https://github.com/omiossec/pwsh-foundry): the sister module for **Foundry Local**.

## License

See [LICENSE](LICENSE).
