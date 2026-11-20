# CLAUDE.md — pwsh-azurefoundry

## Project purpose

PowerShell module (`PwshAzureFoundry`) to call, list, deploy and locate models deployed on an
**Azure AI Foundry resource** (`Microsoft.CognitiveServices/accounts/deployments`), using the
data-plane REST APIs (chat completions, embeddings, decision `/systemone`) and the ARM management
API. Sister project of `PwshFoundry` (Foundry Local), and follows the same conventions.

Design docs (local, git-ignored): `Specifications.draft.md`, `Plan.draft.md`, `Article.draft.md`.
Read them before implementing anything.

`check.draft.md` (local, git-ignored) is the manual functional check list: every public cmdlet and every way
to call it (each parameter set, pipeline input, `-WhatIf`, error cases), with the expected result. **Update it
in the same change as any public cmdlet** (added, removed, or parameters changed): status table, then the
cmdlet's section. Every example runs with `-Verbose`.

The module backs a **dev.to article** on connecting to and managing Foundry models from PowerShell.
`samples/article/*.ps1` are the article's snippets: keep them short and copy-paste runnable, and
never change them without updating `test/Integration/Article.Tests.ps1` and the article draft.
Default output views (`Format.ps1xml`) must read well in screenshots.

## Repository layout

```
pwsh-azurefoundry/
├── src/PwshAzureFoundry/
│   ├── PwshAzureFoundry.psd1         # Manifest (version, explicit exports, Gallery metadata)
│   ├── PwshAzureFoundry.psm1         # Dot-sources Classes/, Private/, Public/; module state
│   ├── PwshAzureFoundry.Format.ps1xml
│   ├── Classes/                      # AzFoundryConnection, AzFoundryMessage
│   ├── Private/                      # Internal helpers (HTTP, ARM, auth, converters)
│   └── Public/                       # One exported function per file
├── test/
│   ├── Unit/                         # Pester 5, HTTP mocked
│   ├── Fixtures/                     # Captured, sanitised JSON responses
│   └── Integration/                  # Tagged Integration, needs a real resource
├── docs/                             # Cmdlet reference, guides
├── samples/                          # Runnable example scripts
├── build/build.ps1                   # Analyze, Test, Build, Publish
└── .github/workflows/
```

## Module conventions

- **Naming**: `Verb-AzFoundryNoun` (e.g. `Invoke-AzFoundryChat`, `New-AzFoundryDeployment`).
  Approved verbs only (`Get-Verb`). Do not use `Deploy-`.
- **One public function per file**; the filename matches the function name.
- **`[CmdletBinding()]`** and `param()` on every function; `SupportsShouldProcess` on every
  `New-`/`Remove-`/state-changing cmdlet; `ConfirmImpact = 'High'` on `Remove-`.
- **Output objects, not strings.** Give each output a `PSTypeName` (`PwshAzureFoundry.*`) and a view
  in `Format.ps1xml`.
- **Request bodies**: include only parameters the caller bound (`$PSBoundParameters`).
- **Errors**: `$PSCmdlet.ThrowTerminatingError()` for fatal errors, `Write-Error` otherwise. Map
  service errors through the private HTTP helpers. Never swallow exceptions.
- **No aliases** unless they are declared in the manifest.

## HTTP and auth rules

- All data-plane calls go through `Invoke-AzFoundryRequest` (or `Invoke-AzFoundryStreamRequest`
  for SSE), and all ARM calls go through `Invoke-AzFoundryArmRequest`. No direct
  `Invoke-RestMethod` in `Public/`.
- `Az.Accounts` is a **soft** dependency: load it via `Import-AzFoundryAzAccounts` only in
  management cmdlets and when Entra ID auth is used. Key-based inference must work without it.
- **Secrets**: API keys are `[SecureString]` in parameters, session state and outputs. Unwrap only
  in `ConvertFrom-AzFoundrySecureString`. Never log, interpolate into errors, or put a key in a URL.
  Redact `Authorization`/`api-key` headers in `-Debug` output.
- HTTPS endpoints only.
- ARM api-version and the Entra scope are module variables, not literals scattered in code.

## Build and test

```powershell
Invoke-Pester ./test/Unit -Output Detailed          # unit tests
./build/build.ps1                                   # analyze + test + build
Import-Module ./src/PwshAzureFoundry/PwshAzureFoundry.psd1 -Force
Invoke-Pester ./test/Integration -Tag Integration   # needs AZURE_FOUNDRY_* env vars
```

Requirements: PowerShell 7.4+, Pester 5.x, PSScriptAnalyzer, Az.Accounts (management and Entra only).

## Testing guidelines

- Pester 5 (`BeforeAll`, `Should`, `Mock … -ModuleName PwshAzureFoundry`).
- Unit tests make no network calls. Mock `Invoke-RestMethod`, `Get-AzAccessToken`, `Get-AzContext`,
  and the stream helper.
- Drive mappings from `test/Fixtures/*.json`. Scrub keys and subscription, tenant and principal ids
  before committing a fixture.
- Integration tests are tagged `Integration`, excluded from CI, and always clean up the deployments they create.
- Test file name: `test/Unit/<FunctionName>.Tests.ps1`.

## Code style

- 4-space indentation, lines ≤ 120 characters, `[Parameter(Mandatory)]` (no `= $true`).
- Prefer `[ValidateSet]`/`[ValidateRange]`/`[ValidatePattern]` over manual checks.
- Comment-based help (synopsis, description, parameters, at least one example) on every public function.
- PSScriptAnalyzer must report no findings.

## Git workflow

- Branch from `main` (`feat/<topic>`, `fix/<topic>`); no direct commits to `main`.
- Imperative commit subjects of 72 characters or fewer (`Add Invoke-AzFoundryChat cmdlet`).
- Never commit `.env`, keys, real fixtures with ids, or `*.draft.md`.
- Run the `pwsh-mod-security-check` agent before a release.
