# Phase 0 spikes

Scripts that probe a real Foundry resource and produce the fixtures in `test/Fixtures/`.
They are not part of the module or of the test suite.

| Script | Purpose |
|---|---|
| `Invoke-DataPlaneSpike.ps1` | Calls chat (hosts × auth headers), streaming, decision, errors, and Entra scopes; saves raw responses |
| `Invoke-ToolCallSpike.ps1` | Phase 4: tool calling (`tool_choice` forms, parallel calls, round trip, streamed `tool_calls` deltas); Entra auth |
| `ConvertTo-SanitizedFixture.ps1` | Copies raw captures to `test/Fixtures/`, replacing GUIDs, emails, account/RG/project names and keys |

```powershell
Connect-AzAccount
./test/Spikes/Invoke-DataPlaneSpike.ps1 -ResourceGroupName <rg> -AccountName <account> -OutputPath $raw
# curate/trim, then:
./test/Spikes/ConvertTo-SanitizedFixture.ps1 -SourcePath $curated -AccountName <account> `
    -ResourceGroupName <rg> -ProjectName <project>
```

Raw output is **not** sanitised. Keep it outside the repo.

## Findings — run of 2026-11-17 (Sweden Central, AIServices S0)

Deployments used: `Mistral-Large-3` (Mistral AI, GlobalStandard, capacity 20) and
`Decision-1.1` (Microsoft-Decision-1.1, GlobalStandard, capacity 50).

### Routes and auth

| Route | `services.ai.azure.com` | `openai.azure.com` | Bearer key | `api-key` | Entra |
|---|---|---|---|---|---|
| `POST /openai/v1/chat/completions` | 200 | 200 | ✔ | ✔ | ✔ |
| `POST /providers/microsoft/v1/systemone` | 200 | 200 | ✔ | ✔ | ✔ |
| `POST /models/chat/completions?api-version=2025-04-01` | 404 | – | | | |
| `POST /models/chat/completions?api-version=2024-05-01-preview` | 200 | – | | ✔ | |
| `GET /models/info` | 404 | – | | | |

- **Both hosts serve both routes.** A single endpoint (`https://<account>.services.ai.azure.com`) is enough.
- The API key works as `Authorization: Bearer <key>` and as `api-key: <key>`.
- Entra tokens for **both** `https://cognitiveservices.azure.com` and `https://ai.azure.com` are accepted
  on chat and systemone.
- The Azure AI Model Inference route (`/models/...`) only answers with `2024-05-01-preview`. The
  `2025-04-01` version from the docs returns 404. **Not used by the module.**
- Two calls took 36–44 s (the first `api-key` chat call and the first Entra chat call), and every
  other call took 0.1–1.5 s. The cause is unknown and the default timeout of 120 s covers it.

### Chat

- Response: `{ id, model, choices[{index, message{role, content}, finish_reason}], usage{prompt_tokens,
  completion_tokens, total_tokens, audio_prompt_tokens}, created, object, prompt_filter_results }`.
- `model` in the response is the **lower-case model name** (`mistral-large-3`), not the deployment name.
- Parameter ranges are model-specific: Mistral rejects `temperature: 5` with
  `400 unsupported_request_value` ("must be in the range [0.0 and 1.0]").
- Unknown body fields are rejected (`400 unrecognized_request_argument`). `-ExtraBody` therefore only
  works for parameters the model knows. The `extra-parameters` header (Model Inference API) was not tested on `/openai/v1`.

### Streaming (`chat-stream.txt`)

- Lines are `data: {json}` separated by **several** blank lines, with no `event:` lines. The stream ends with `data: [DONE]`.
- The first chunk carries `delta.role = assistant` and empty content.
- With `stream_options.include_usage = true`, `usage` arrives on the **last content chunk**, together
  with `finish_reason: stop`, not in a separate chunk.

### Decision (`/systemone`)

Response:

```json
{ "model": "microsoft-decision-1.1",
  "answers": {
    "billing":  { "type": "noul",   "noul": 0.997 },
    "team":     { "type": "choice", "choice": "finance", "confidence": 0.90,
                  "probabilities": { "finance": 0.93, "sales": 0.02, "support": 0.05 } },
    "priority": { "type": "score",  "score": 1.39, "confidence": 0.28,
                  "legend": { "0": "low", "1": "medium", "2": "high" },
                  "probabilities": { "0": 0.13, "1": 0.35, "2": 0.52 } } },
  "usage": { "input_tokens": 91, "output_tokens": 3 } }
```

- `noul` is the probability that the predicate is true.
- `score` is the expected value over level indexes (0-based). `legend` maps index → label.
- Request question types accepted: `noul`, `choice`, `score` (validation error lists exactly these).
- The brief's deployment name `Decision-1` does not exist on the lab resource. It is `Decision-1.1`.

### Error shapes (the mapper must handle all four)

| Shape | Example | Fixture |
|---|---|---|
| `{error:{code:"401"\|"404", message}}` (gateway, `code` is a string number) | bad key, unknown route | `error-401.json`, `error-route-not-found-404.json` |
| `{error:{type, code, message}}` (OpenAI style) | unknown deployment on chat | `error-deployment-not-found.json` |
| `{error:{code, message, details}}` | bad parameter value, unknown argument, unknown decision deployment | `error-unsupported-value-400.json`, `error-unrecognized-argument-400.json`, `error-decision-deployment-not-found.json` |
| `{detail:[{type, loc[], msg}]}` (422 validation, systemone) | bad question type | `error-decision-validation-422.json` |

### Rate-limit headers

`x-ratelimit-limit-requests`, `-remaining-requests`, `-reset-requests`, `-limit-tokens`,
`-remaining-tokens`, `-reset-tokens`, `-renewalperiod-*` (60 s), and `x-ratelimit-key` (= deployment name).
For GlobalStandard, **capacity N = N requests/min and N×1000 tokens/min** (20 → 20 RPM / 20k TPM).

### ARM (management plane)

- `Microsoft.CognitiveServices/accounts` accepts api-versions `2025-06-01`, `2025-09-01`,
  `2025-10-01-preview` and `2026-03-01`.
- `properties.endpoints` keys: `AI Foundry API` → `https://<a>.services.ai.azure.com/`,
  `OpenAI Language Model Instance API` → `https://<a>.openai.azure.com/`, plus about 70 others.
  The account also exposes `defaultProject` and `associatedProjects`.
- `GET …/models` returns 187 entries in a single page (no `nextLink`). The shape is **flat**:
  `format, name, version, isDefaultVersion, skus[{name, usageName, capacity{default, maximum},
  deprecationDate, rateLimits[]}], maxCapacity, capabilities{…: "true"}, lifecycleStatus
  (GenerallyAvailable|Preview|Deprecated), deprecation{inference}`. The fixture is trimmed to 7 models.
- `GET …/deployments`: `sku{name, capacity}`, `properties{model{format, name, version},
  provisioningState, capabilities, raiPolicyName, …}`.
- `POST …/listKeys` → `{ key1, key2 }`.

## Findings — `Invoke-ManagementSpike.ps1`, 2026-11-17

Temporary deployments `spike-embed` (OpenAI text-embedding-3-small v1) and `spike-cohere`
(Cohere-embed-v3-english v1), both GlobalStandard with capacity 1. Both were deleted at the end, and
the resource is back to `Mistral-Large-3` + `Decision-1.1`.

### Deployment lifecycle — sync **or** async depending on the model

| Call | OpenAI model | Partner model (Cohere) |
|---|---|---|
| `PUT …/deployments/{n}` | **201**, `provisioningState: Succeeded`, no async header | **201**, `provisioningState: Creating`, `Location` header |
| Poll `Location` | – | **200** `{status: Running}` … **200** `{status: Succeeded, endTime}` (about 65 s), never 202 |
| `DELETE …/deployments/{n}` | **200**, empty body | **202** + `Location`, then the same 200 polling (about 25 s) |

- No `Azure-AsyncOperation` header was seen. The `Location` URL is `…/locations/{region}/operationResults/{id}?api-version=…&t=…&c=…&s=…&h=…`
  (signed query: never log it in full).
- The PUT body is `{sku:{name, capacity}, properties:{model:{format, name, version}}}`. The response adds
  `versionUpgradeOption`, `currentCapacity`, `capabilities`, `raiPolicyName`, and `rateLimits`.
- **Data-plane propagation:** right after `Succeeded`, `/openai/v1/embeddings` returned **404
  DeploymentNotFound** and worked about 20 s later. While a partner deployment is still provisioning,
  the data plane returns **400** `{"error":{"code":400,"message":"…being created…","responseCode":"DeploymentCreating"}}`
  (a fifth error shape, with a **numeric** `code`).

### Partner model / marketplace

- Deploying `Cohere-embed-v3-english` (format `Cohere`) **succeeded with no marketplace step**. No
  `Microsoft.SaaS/resources` was created in the subscription, and no agreement error came back.
  The marketplace handling in spec Q-3 is therefore not needed for this subscription. The module
  should still surface a clear message if a marketplace error appears on another subscription type.

### Embeddings

- `POST /openai/v1/embeddings` with `{model, input: string | string[], dimensions?}` →
  `{object: list, data[{object: embedding, index, embedding: float[]}], model, usage{prompt_tokens, total_tokens}}`.
- `dimensions: 256` is honoured by text-embedding-3-small.
- The deployment's `capabilities.embeddingsMaxInputs` = `2048` (max batch size), which the module can use.

### 429 / throttling

- Not reproduced: 30 tiny requests to `Mistral-Large-3` (20 RPM) gave 30 × 200, and
  `x-ratelimit-remaining-requests` never went below 14. Several requests **took 35–55 s** with
  plenty of quota left, so the long calls seen in the first spike are service-side latency, not
  throttling. The 429 mapping is implemented from the docs, with no fixture.
- Content-filter 400: not attempted (it needs a harmful prompt). The mapping is implemented from the docs.

### New fixtures

`arm-deployment-put-sync`, `arm-deployment-put-async` (+ meta with `Location`), `arm-operation-running`,
`arm-operation-succeeded`, `arm-deployment-delete-sync`, `arm-deployment-delete-async`, `embedding`,
`embedding-dimensions`, `error-deployment-creating-400`, `chat-tiny`.
