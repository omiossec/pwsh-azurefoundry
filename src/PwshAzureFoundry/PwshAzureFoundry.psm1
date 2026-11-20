#Requires -Version 7.4

# --- Module state -------------------------------------------------------------------------------
# Active connection set by Connect-AzFoundry (AzFoundryConnection), cleared by Disconnect-AzFoundry.
$script:AzFoundryConnection = $null

# Entra ID token cache, shared by data-plane and ARM calls. Key: '<resource>|<account>|<tenant>'.
# Value: [pscustomobject]@{ Token = [SecureString]; ExpiresOn = [datetimeoffset] }. Refreshed 5 min before expiry.
$script:AzFoundryTokenCache = @{}

# Entra scope for data-plane tokens (spec section 2.1: both cognitiveservices and ai.azure.com work).
$script:AzFoundryTokenScope = 'https://cognitiveservices.azure.com/.default'

# Az.Accounts is a soft dependency (management cmdlets and Entra ID auth only).
$script:AzFoundryAzAccountsMinVersion = '2.13.0'

# ARM management plane (spec sections 2.1 and 4.2). Sovereign clouds are out of scope for v1.
$script:AzFoundryArmBaseUri         = 'https://management.azure.com'
$script:AzFoundryArmApiVersion      = '2025-06-01'
$script:AzFoundryArmPollIntervalSec = 5      # used when an async response has no Retry-After header
$script:AzFoundryArmPollTimeoutSec  = 1800

# Readiness check of New-AzFoundryDeployment: the data plane answers 404 for about 20 s after Succeeded (spike).
$script:AzFoundryReadinessTimeoutSec  = 180
$script:AzFoundryReadinessIntervalSec = 5

# HTTP behaviour (spec section 8). MaxRetry is the number of retries after the first attempt.
$script:AzFoundryMaxRetry             = 3
$script:AzFoundryMaxRetryDelaySec     = 60
$script:AzFoundryRetryableStatusCodes = @(429, 500, 502, 503, 504)
$script:AzFoundryDefaultTimeoutSec    = 120

# Environment variable fallback (spec section 4.1).
$script:AzFoundryEndpointEnvVar = 'AZURE_FOUNDRY_ENDPOINT'
$script:AzFoundryApiKeyEnvVar   = 'AZURE_FOUNDRY_API_KEY'

$script:AzFoundryModuleVersion = $MyInvocation.MyCommand.ScriptBlock.Module.Version
$script:AzFoundryUserAgent     = 'PwshAzureFoundry/{0} PowerShell/{1}' -f @(
    $script:AzFoundryModuleVersion, $PSVersionTable.PSVersion
)

# --- Load sources -------------------------------------------------------------------------------
foreach ($folder in @('Classes', 'Private', 'Public')) {
    $path = Join-Path $PSScriptRoot $folder
    if (Test-Path -LiteralPath $path) {
        Get-ChildItem -LiteralPath $path -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { . $_.FullName }
    }
}
