# Samples

Runnable scripts. Each has comment-based help: `Get-Help ./samples/<script>.ps1 -Full`.

## With the module

They need PwshAzureFoundry, and most use the current connection: run `Connect-AzFoundry` first (or set
`AZURE_FOUNDRY_ENDPOINT` and `AZURE_FOUNDRY_API_KEY`, see [docs/README.md](../docs/README.md#authentication)).

| Script | Shows | Needs |
|---|---|---|
| [`chat-quickstart.ps1`](chat-quickstart.ps1) | Connect with a key, one prompt, a two-turn conversation | a chat deployment |
| [`interactive-chat.ps1`](interactive-chat.ps1) | Streaming chat REPL (`-Stream -PassThru`), history, `/reset` | a chat deployment |
| [`decision-triage.ps1`](decision-triage.ps1) | Predicate, choice and score questions over a CSV of tickets, sorted by urgency | a decision deployment |
| [`embedding-search.ps1`](embedding-search.ps1) | Embeddings in one batch and cosine similarity search | an embedding deployment |
| [`deploy-and-call.ps1`](deploy-and-call.ps1) | Connect through ARM, list the catalogue, deploy, call, delete (`-WhatIf` supported) | Az.Accounts, Cognitive Services Contributor |
| [`tool-calling.ps1`](tool-calling.ps1) | The tool-calling loop: the model asks, the script runs the function and answers | a chat deployment that supports tools |
| [`article-teaser.ps1`](article-teaser.ps1) | The article's closing block: steps 01 to 07 of `article/` in a few cmdlets | Az.Accounts, the Gallery module |

```powershell
Connect-AzAccount
Connect-AzFoundry -ResourceGroupName rg-lab -AccountName <resource>
./samples/interactive-chat.ps1 -Model Mistral-Large-3
./samples/decision-triage.ps1 -Model Decision-1.1
```

## Without the module: `article/`

[`article/`](article/) holds the snippets of the dev.to article. They do the same tasks with **plain REST**
(Az.Accounts, `Invoke-RestMethod` and `HttpClient`, no PwshAzureFoundry) to show what a module saves you.
Run them in order in one session: each one uses the variables of the previous ones.

| Script | Step |
|---|---|
| `01-connect.ps1` | ARM token, endpoint of the resource, key with `listKeys` |
| `02-list-models.ps1` | Catalogue of deployable models, deployed models |
| `03-select-model.ps1` | Pick a chat and a decision deployment |
| `04-chat-completion.ps1` | One chat completion |
| `05-streaming.ps1` | Streamed completion (server-sent events) with `HttpClient` |
| `06-conversation.ps1` | Multi-turn conversation (the Paris example) |
| `07-decision.ps1` | Decision model: the urgency example, then ticket triage |
| `08-deploy.ps1` | Deploy `text-embedding-3-small`, poll, wait for the data plane |
| `09-cleanup.ps1` | Delete the deployment, dispose of the secrets and drop them from the session |

```powershell
Connect-AzAccount
$env:AZURE_FOUNDRY_RG = 'rg-lab'; $env:AZURE_FOUNDRY_ACCOUNT = '<resource>'
Get-ChildItem ./samples/article/*.ps1 | Sort-Object Name | ForEach-Object { . $_.FullName }
```

`test/Integration/Article.Tests.ps1` runs them in this order against a real resource, then runs
`article-teaser.ps1` with the module from the PowerShell Gallery. Change a snippet, the test and the article
together. PSScriptAnalyzer reports `ConvertTo-SecureString -AsPlainText` and
`Write-Host` in these snippets: they are kept on purpose, because handling the key and printing a stream by
hand is part of what the article shows.
