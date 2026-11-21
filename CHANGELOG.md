# Changelog

All notable changes to PwshAzureFoundry are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the module uses
[Semantic Versioning](https://semver.org/).

Pre-releases (`-alpha`, `-beta`, …) are built by the release workflow as private GitHub artifacts. Only
stable versions are published to the PowerShell Gallery.

## [Unreleased]

## [0.1.0] - 2026-11-21

First stable version, published to the PowerShell Gallery. Changes since 0.1.0-alpha:

### Changed

- **Breaking:** an endpoint outside Azure (`*.services.ai.azure.com`, `*.openai.azure.com`,
  `*.cognitiveservices.azure.com`) is refused with `AzFoundryEndpointNotAzure` unless `-AllowCustomEndpoint` is
  given to `Connect-AzFoundry`, `Invoke-AzFoundryChat`, `Invoke-AzFoundryEmbedding` or `Invoke-AzFoundryDecision`;
  then a warning is shown once per host. `AZURE_FOUNDRY_ENDPOINT` accepts only Azure hosts.
- `POST` requests (chat, embeddings, decision, `listKeys`) are retried on 429 only, no longer on 5xx: a 5xx can
  come after the model has run and been billed. `GET`, `PUT` and `DELETE` are still retried on 429 and 5xx.
- The readiness probe of `New-AzFoundryDeployment` follows the session's auth mode: with an Entra ID session it
  probes with a token and never calls `listKeys`.

## [0.1.0-alpha] - 2026-11-21

First pre-release.

### Added

- Connection: `Connect-AzFoundry` (endpoint and `[SecureString]` key, Entra ID, or from the resource
  through Az.Accounts), `Get-AzFoundryConnection`, `Disconnect-AzFoundry`. Data-plane cmdlets fall back
  to `AZURE_FOUNDRY_ENDPOINT` / `AZURE_FOUNDRY_API_KEY`.
- Chat: `Invoke-AzFoundryChat` with streaming (`-Stream`), multi-turn messages (`New-AzFoundryMessage`)
  and basic tool calling (`New-AzFoundryTool`, `-Tool`, `-ToolChoice`).
- Embeddings: `Invoke-AzFoundryEmbedding`, with pipeline input.
- Decision models: `Invoke-AzFoundryDecision` (`/systemone`), one object per question.
- Management (Az.Accounts + ARM): `Get-AzFoundryModel`, `Get-AzFoundryDeployment`,
  `New-AzFoundryDeployment` (with a readiness probe), `Remove-AzFoundryDeployment`, `Get-AzFoundryEndpoint`.
- Service error mapping, retry on 429 honouring `Retry-After`, and `Authorization` / `api-key` redaction
  in `-Debug` output.
- Formatting views, cmdlet reference (`docs/`), samples and integration tests.
- Release workflow (`.github/workflows/release.yml`): on a `v*` tag, checks the tag against the manifest,
  runs analyze, tests and build, and uploads the module as an artifact. Stable tags are then published to
  the PowerShell Gallery.

### Security

From the phase 9 review of the module and the samples:

- The session key is never reused for an endpoint of the same account on a non-default port.
- `Get-AzFoundryDeployment -Name` rejects `.` and `..`; `-ResourceGroupName` rejects names ending with a period
  (all cmdlets).
- The build fails when anything other than module code (`.ps1`, `.psm1`, `.psd1`, `.ps1xml`) would be packaged.
- Samples: `deploy-and-call.ps1` refuses an existing deployment name (`sample-*` only) and cleans up even when the
  deployment fails; `decision-triage.ps1` escapes formula characters in ticket text; parameter validation and a
  tool-argument check in the other samples.

[Unreleased]: https://github.com/omiossec/pwsh-azurefoundry/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/omiossec/pwsh-azurefoundry/compare/v0.1.0-alpha...v0.1.0
[0.1.0-alpha]: https://github.com/omiossec/pwsh-azurefoundry/releases/tag/v0.1.0-alpha
