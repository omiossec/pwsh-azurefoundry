# PwshAzureFoundry documentation

Reference for the PwshAzureFoundry module: authentication, every cmdlet, and troubleshooting. For a quick
start see the [repository README](../README.md); for runnable scripts see [`samples/`](../samples/README.md).

- [Terminology: what "serverless" means](#terminology-what-serverless-means)
- [Authentication](#authentication)
- [Cmdlet reference](#cmdlet-reference)
- [Output objects](#output-objects)
- [Troubleshooting](#troubleshooting)

`Get-Help <cmdlet> -Full` shows the same information in the terminal.

## Terminology: what "serverless" means

Azure has two kinds of pay-per-token deployments, and both are called "serverless" in places:

| | Classic serverless API | Foundry resource deployment |
|---|---|---|
| ARM type | `Microsoft.MachineLearningServices/workspaces/serverlessEndpoints` | `Microsoft.CognitiveServices/accounts/deployments` |
| Needs | a hub project, a marketplace subscription per partner model | a Foundry resource (kind `AIServices`) |
| Endpoint | one endpoint and key **per model** | one endpoint and key **per resource**; the `model` field of the request picks the deployment |
| SKU | – | `GlobalStandard`, `DataZoneStandard`, `Standard` |
| Status | legacy | what Microsoft recommends now |

Both bill per token, with no VM or capacity to manage. **The module supports Foundry resource deployments
only.**

## Authentication

### Three ways to connect

```powershell
# 1. API key: only the module is needed (no Az.Accounts)
$key = Read-Host -AsSecureString 'API key'
Connect-AzFoundry -Endpoint 'https://<resource>.services.ai.azure.com' -ApiKey $key

# 2. Entra ID: requests use a token from Az.Accounts
Connect-AzAccount
Connect-AzFoundry -Endpoint 'https://<resource>.services.ai.azure.com' -UseEntraId

# 3. From the resource: the endpoint and the key are read through ARM, nothing is copied by hand
Connect-AzAccount
Connect-AzFoundry -ResourceGroupName 'rg-lab' -AccountName '<resource>'              # key
Connect-AzFoundry -ResourceGroupName 'rg-lab' -AccountName '<resource>' -UseEntraId  # Entra ID
```

- Both host forms are accepted (`https://<resource>.services.ai.azure.com` and `https://<resource>.openai.azure.com`);
  a trailing path such as `/openai/v1` is removed. Only `https://` endpoints are allowed.
- The key is sent in the `api-key` header and Entra ID tokens in `Authorization: Bearer`. Tokens (scope
  `https://cognitiveservices.azure.com/.default`) are cached and refreshed 5 minutes before they expire.
- Connecting with `-ResourceGroupName`/`-AccountName` also sets the default resource of the management
  cmdlets, so `Get-AzFoundryDeployment` then needs no parameters.
- `Get-AzFoundryConnection` shows the connection, never the key. `Disconnect-AzFoundry` clears it.

### Where the connection comes from

Each data-plane cmdlet (`Invoke-AzFoundryChat`, `Invoke-AzFoundryEmbedding`, `Invoke-AzFoundryDecision`)
uses the first of:

1. its own `-Endpoint` with `-ApiKey` or `-UseEntraId`;
2. the connection set by `Connect-AzFoundry`;
3. the environment variables `AZURE_FOUNDRY_ENDPOINT` and `AZURE_FOUNDRY_API_KEY`.

When the environment variables are used, `Get-AzFoundryConnection` shows `Source = Environment` and
`-Verbose` says so. The key is turned into a SecureString as soon as it is read.

> **Warning.** An environment variable holds the key in **plain text**, readable by any process of the
> same user. Use it for CI and containers (from a secret store); interactively, prefer `Connect-AzFoundry`.

```powershell
# CI example (GitHub Actions secret mapped to the environment)
$env:AZURE_FOUNDRY_ENDPOINT = 'https://<resource>.services.ai.azure.com'
# $env:AZURE_FOUNDRY_API_KEY comes from the secret store
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'ping'
```

### Management cmdlets

`Get-AzFoundryModel`, `Get-AzFoundryDeployment`, `New-AzFoundryDeployment`, `Remove-AzFoundryDeployment`
and `Get-AzFoundryEndpoint` call Azure Resource Manager with a token from `Get-AzAccessToken`. They need
**Az.Accounts** (2.13.0 or later) and `Connect-AzAccount`. Az.Accounts is loaded only when needed: key-based
inference works without it.

The target resource comes from `-ResourceGroupName`/`-AccountName` (and `-SubscriptionId`), or else from
`Connect-AzFoundry -ResourceGroupName … -AccountName …`. The subscription defaults to the one of the current
Az context.

### Roles (RBAC)

| Task | Role on the Foundry resource |
|---|---|
| Call models with Entra ID | **Cognitive Services User** |
| List models and deployments, read the endpoint | Reader |
| Read the keys (`-IncludeKey`, `Connect-AzFoundry -ResourceGroupName`), deploy, delete | **Cognitive Services Contributor** |

Key-based calls need no role, only the key. A resource with `disableLocalAuth = true` (see
`Get-AzFoundryEndpoint`) refuses keys: use `-UseEntraId`.

## Cmdlet reference

| Area | Cmdlets |
|---|---|
| Connection | [`Connect-AzFoundry`](#connect-azfoundry), [`Get-AzFoundryConnection`](#get-azfoundryconnection), [`Disconnect-AzFoundry`](#disconnect-azfoundry) |
| Inference | [`New-AzFoundryMessage`](#new-azfoundrymessage), [`New-AzFoundryTool`](#new-azfoundrytool), [`Invoke-AzFoundryChat`](#invoke-azfoundrychat), [`Invoke-AzFoundryEmbedding`](#invoke-azfoundryembedding), [`Invoke-AzFoundryDecision`](#invoke-azfoundrydecision) |
| Management | [`Get-AzFoundryModel`](#get-azfoundrymodel), [`Get-AzFoundryDeployment`](#get-azfoundrydeployment), [`New-AzFoundryDeployment`](#new-azfoundrydeployment), [`Remove-AzFoundryDeployment`](#remove-azfoundrydeployment), [`Get-AzFoundryEndpoint`](#get-azfoundryendpoint) |

Every data-plane cmdlet also takes `-Endpoint`, `-ApiKey`, `-UseEntraId` (override the connection) and
`-TimeoutSec` (default 120). Every management cmdlet takes `-ResourceGroupName`, `-AccountName` and
`-SubscriptionId`. These are not repeated below.

### Connect-AzFoundry

Sets the endpoint and the authentication of the session.

| Parameter set | Parameters |
|---|---|
| ApiKey | `-Endpoint <string>` `-ApiKey <SecureString>` |
| EntraId | `-Endpoint <string>` `-UseEntraId` |
| Arm | `-ResourceGroupName <string>` `-AccountName <string>` [`-SubscriptionId <string>`] [`-UseEntraId`] |

`-PassThru` outputs the `PwshAzureFoundry.Connection`. Supports `-WhatIf`. Connecting again replaces the
connection.

### Get-AzFoundryConnection

Outputs the connection the data-plane cmdlets use (`Source = Session` or `Environment`), or nothing.

```powershell
Get-AzFoundryConnection

AccountName  Endpoint                                   AuthMode Source
-----------  --------                                   -------- ------
lab-foundry  https://lab-foundry.services.ai.azure.com  ApiKey   Session
```

### Disconnect-AzFoundry

Clears the connection and the cached Entra ID tokens. It does not run `Disconnect-AzAccount` and does not
change the environment variables.

### New-AzFoundryMessage

Builds a chat message (`AzFoundryMessage`) in memory.

| Parameter | Notes |
|---|---|
| `-Role` | `system`, `user`, `assistant`, `tool` |
| `-Content` | text; any other object is converted to compact JSON. Pipeline input (one message per item). |
| `-ToolCallId` | required with `-Role tool`, and only allowed with it |
| `-Name` | optional participant name |

```powershell
$history = @(
    New-AzFoundryMessage -Role user      -Content 'I am going to Paris, what should I see?'
    New-AzFoundryMessage -Role assistant -Content 'The Eiffel Tower, the Louvre, Notre-Dame...'
    New-AzFoundryMessage -Role user      -Content 'What is so great about #1?'
)
```

### New-AzFoundryTool

Builds a function tool definition (`AzFoundryTool`) for `Invoke-AzFoundryChat -Tool`.

| Parameter | Notes |
|---|---|
| `-Name` | `^[a-zA-Z0-9_-]{1,64}$` |
| `-Description` | what the function does; the model reads it to decide whether to call it |
| `-Parameter` | JSON Schema of the arguments (`type = 'object'`, `properties`, `required`); omit for no arguments |

### Invoke-AzFoundryChat

`POST /openai/v1/chat/completions`. The deployment is picked by `-Model`.

| Parameter | Notes |
|---|---|
| `-Model` | deployment name; binds from the `Name` property of piped objects |
| `-Prompt` / `-Message` | one user message, or a whole conversation (`AzFoundryMessage` or `@{ role; content }`, pipeline) |
| `-SystemPrompt` | system message added at the start |
| `-MaxTokens`, `-Temperature`, `-TopP`, `-Stop`, `-Seed` | sent only when given; ranges are model-specific (Mistral: temperature 0–1) |
| `-ResponseFormat` | `text`, `json_object`, or a hashtable (JSON schema) |
| `-Tool`, `-ToolChoice` | tool definitions; `auto`, `none`, `required` or a function name |
| `-ExtraBody` | hashtable merged last into the body, for parameters the cmdlet does not expose |
| `-Stream` [`-PassThru`] | output `ChatChunk` objects as they arrive; `-PassThru` adds the final `ChatResult` |
| `-Raw` | output the parsed service response |

Output: `PwshAzureFoundry.ChatResult`. Append its `Message` to the history to continue the conversation.

```powershell
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Hello'
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Message $history -MaxTokens 2048 -Temperature 0.8 -TopP 0.1

# Print a streamed answer: -Stream writes objects, never to the host
Invoke-AzFoundryChat -Model 'Mistral-Large-3' -Prompt 'Tell me a story' -Stream |
    ForEach-Object { Write-Host $_.Content -NoNewline }

# Same prompt to every Mistral deployment
Get-AzFoundryDeployment -Name 'Mistral*' | Invoke-AzFoundryChat -Prompt 'Say hi in five words'
```

**Tool calling.** The module sends the tool definitions and returns the calls the model asks for; it never
runs your functions. When `FinishReason` is `tool_calls`, add `ChatResult.Message` to the history, run your
code for each `ToolCalls` entry, answer with `New-AzFoundryMessage -Role tool -ToolCallId $call.Id`, and call
the cmdlet again. See [`samples/tool-calling.ps1`](../samples/tool-calling.ps1). With `-Stream`, tool calls
appear only in the final `ChatResult` (`-PassThru`).

### Invoke-AzFoundryEmbedding

`POST /openai/v1/embeddings`.

| Parameter | Notes |
|---|---|
| `-Model` | embedding deployment name |
| `-InputText` | texts to embed; pipeline input |
| `-Dimensions` | vector length, for models that support it (`text-embedding-3-*`) |
| `-EncodingFormat` | `float` only |
| `-BatchSize` | texts per request (default 16; deployment limit 2048) |
| `-Raw` | output each parsed response (with usage) |

Output: one `PwshAzureFoundry.Embedding` per text, in input order.

```powershell
'first text', 'second text' | Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small' -Dimensions 256
```

### Invoke-AzFoundryDecision

`POST /providers/microsoft/v1/systemone`. Decision models (Microsoft-Decision) do not write text: they
answer typed questions about a state.

| Parameter | Question type | Example |
|---|---|---|
| `-Predicate` | `noul`: probability that a statement is true | `@{ urgent = 'Does this message convey urgency?' }` |
| `-Choice` | `choice`: one of several options | `@{ team = [ordered]@{ sales = 'Sales'; support = 'Support' } }` |
| `-Score` | `score`: position on an ordered scale, lowest first | `@{ priority = 'low', 'medium', 'high' }` |
| `-Question` | raw definitions sent as-is | `@{ q = @{ type = 'noul'; instructions = '…' } }` |

`-State` is a string or any object (sent as JSON), and accepts pipeline input (one request per state).
At least one question is required; ids must be unique across the parameters. `-Threshold` (default 0.5) is
the cut-off of a predicate's `Answer`. `-Raw` outputs the service response.

Output: one `PwshAzureFoundry.DecisionAnswer` per question.

```powershell
Invoke-AzFoundryDecision -Model 'Decision-1.1' `
    -State 'The payment integration still fails. Please help today.' `
    -Predicate @{ urgent = 'Does this message convey urgency?' }
```

### Get-AzFoundryModel

`GET …/accounts/{account}/models`: the catalogue of models you can deploy on this resource (it depends on the
region and the subscription), not the deployed ones.

| Parameter | Notes |
|---|---|
| `-Name` | wildcards allowed |
| `-Format` | publisher: `OpenAI`, `Mistral AI`, `Cohere`, `Microsoft`…; wildcards allowed |
| `-Sku` | keep models deployable with this SKU (`GlobalStandard`…) |
| `-Task` | keep models with all these capabilities: `chatCompletion`, `embeddings`, `decision`… |
| `-AllVersions` | every version instead of the default (or latest) one |
| `-IncludeDeprecated` | include deprecated models |

```powershell
Get-AzFoundryModel -Format 'Mistral AI' -Task chatCompletion
```

### Get-AzFoundryDeployment

`GET …/accounts/{account}/deployments`. `-Name` (wildcards allowed; without a wildcard, a missing deployment
is an error). The `Name` of a deployment is what the inference cmdlets take as `-Model`.

### New-AzFoundryDeployment

`PUT …/accounts/{account}/deployments/{name}`. Supports `-WhatIf` and `-Confirm`.

| Parameter | Notes |
|---|---|
| `-ModelName` or pipeline `Model` | catalogue model (from `Get-AzFoundryModel`) |
| `-Name` | deployment name, defaults to the model name |
| `-ModelVersion`, `-ModelFormat` | default to the catalogue (default or latest version) |
| `-SkuName` | `GlobalStandard` (default), `DataZoneStandard`, `Standard`… |
| `-Capacity` | units, default 1; for GlobalStandard N units = N requests and N×1000 tokens per minute |
| `-RaiPolicyName` | content filter, defaults to the resource default |
| `-NoWait` | return as soon as ARM accepts the request |
| `-SkipReadinessCheck` | do not wait for the data plane to answer |

Without `-NoWait`, the cmdlet waits for `Succeeded` (OpenAI models: at once; partner models: about a
minute), then sends a minimal request until the deployment answers (about 20 s; a few tokens). It refuses to
replace an existing deployment.

```powershell
Get-AzFoundryModel -Name 'text-embedding-3-small' | New-AzFoundryDeployment -Capacity 10 -WhatIf
```

### Remove-AzFoundryDeployment

`DELETE …/accounts/{account}/deployments/{name}`. `ConfirmImpact = High`: add `-Confirm:$false` in scripts.
Pipeline input from `Get-AzFoundryDeployment`. `-NoWait` returns before a partner deployment is gone.

```powershell
Get-AzFoundryDeployment -Name 'test-*' | Remove-AzFoundryDeployment -Confirm:$false
```

### Get-AzFoundryEndpoint

`GET …/accounts/{account}`: the Foundry host (`Endpoint`, for `Connect-AzFoundry`), the OpenAI host, the
routes the module calls (`ChatCompletionsUri`, `EmbeddingsUri`, `DecisionUri`), every named endpoint of the
resource (`Endpoints`), and `DisableLocalAuth`/`PublicNetworkAccess`. `-IncludeKey` adds `Key1` and `Key2`
as SecureString (`POST …/listKeys`).

## Output objects

| Type | Main properties |
|---|---|
| `PwshAzureFoundry.Connection` | AccountName, Endpoint, AuthMode, Source, ResourceGroupName, SubscriptionId (never the key) |
| `PwshAzureFoundry.ChatResult` | Content, Role, FinishReason, ToolCalls, Usage, RateLimit, Model, Id, Created, Message, Raw |
| `PwshAzureFoundry.ChatChunk` | Content, FinishReason, Index |
| `PwshAzureFoundry.ToolCall` | Id, Name, Arguments (hashtable, `$null` if the JSON is invalid), ArgumentsJson |
| `PwshAzureFoundry.Embedding` | Index, Text, Vector (`[float[]]`), Dimensions, Model |
| `PwshAzureFoundry.DecisionAnswer` | Question, Type, Answer, Value, Confidence, Probabilities, Model, InputTokens, OutputTokens, RateLimit, State |
| `PwshAzureFoundry.Model` | Name, Version, Format, Publisher, LifecycleStatus, DeprecationDate, Skus, Tasks, Capabilities |
| `PwshAzureFoundry.Deployment` | Name, ModelName, Version, Format, Sku, Capacity, ProvisioningState, RaiPolicy, CreatedAt |
| `PwshAzureFoundry.Endpoint` | Endpoint, OpenAIEndpoint, ChatCompletionsUri, EmbeddingsUri, DecisionUri, Endpoints, Key1, Key2 |

`DecisionAnswer` by question type:

| | `noul` | `choice` | `score` |
|---|---|---|---|
| `Answer` | `$true` when the probability ≥ `-Threshold` | chosen option key | label of the most probable level |
| `Value` | probability | – | expected level index (0-based) |
| `Confidence` | probability of the `Answer` | service confidence | service confidence |
| `Probabilities` | – | option → probability | label → probability |

Errors are `ErrorRecord`s with a category (`AuthenticationError`, `PermissionDenied`, `ObjectNotFound`,
`InvalidArgument`, `LimitsExceeded`, `SecurityError`…), the service code and message, and a hint in
`ErrorDetails.RecommendedAction`. Retries (429, 500, 502, 503, 504) honour `Retry-After`, up to 3 times.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `404 DeploymentNotFound` right after a deployment | The data plane knows a new deployment about 20 s after ARM says `Succeeded`. `New-AzFoundryDeployment` waits for it unless you use `-NoWait` or `-SkipReadinessCheck`. Otherwise check the name with `Get-AzFoundryDeployment` (the deployment name, not the model name). |
| `400 DeploymentCreating` | A partner deployment is still provisioning. Wait until `Get-AzFoundryDeployment` shows `Succeeded`. |
| `401` | Wrong key, or a key for another resource. Read it again with `Get-AzFoundryEndpoint -IncludeKey`, or reconnect with `Connect-AzFoundry -ResourceGroupName … -AccountName …`. With Entra ID: run `Connect-AzAccount`. |
| `403` | Missing role: Cognitive Services User to call models with Entra ID, Cognitive Services Contributor to read keys and deploy. Role assignments can take a few minutes to apply. Keys are refused when `DisableLocalAuth` is true. |
| `429` / `LimitsExceeded` | The deployment's requests or tokens per minute are used up. The module retries; raise `-Capacity` if it keeps happening. |
| Quota error on `New-AzFoundryDeployment` | The subscription quota for this model and SKU in this region is too low. Use a smaller `-Capacity` (the default is 1), another SKU, or request more quota in the Foundry portal. |
| Marketplace or terms error on a partner model | Some subscription types must accept the publisher's marketplace terms first (a pay-as-you-go subscription did not need it). Deploy the model once from the Foundry portal to accept them, then retry. Free and trial subscriptions cannot deploy partner models. |
| `SecurityError` / `content_filter` | The content filter (RAI policy) of the deployment blocked the prompt or the answer. Rephrase, or deploy with another `-RaiPolicyName`. |
| `400 unsupported_request_value` | A parameter is out of the model's range (Mistral: `-Temperature` 0–1). |
| `400 unrecognized_request_argument` | A field in `-ExtraBody` is not known to the model. |
| `422` with `-ToolChoice <function>` | Some models (Mistral) do not accept a forced function. Pass only that tool with `-Tool` and use `-ToolChoice required`. |
| A call takes 30–60 s | Service-side latency seen on some calls, with quota left. The default timeout (120 s) covers it; `-Verbose` shows the elapsed time. |
| `Az.Accounts is required` | Management cmdlets and `-UseEntraId` need Az.Accounts: `Install-PSResource Az.Accounts`, then `Connect-AzAccount`. |

`-Verbose` shows each request (method, route, status, elapsed time). `-Debug` adds the request bodies,
with the `api-key` and `Authorization` headers redacted.
