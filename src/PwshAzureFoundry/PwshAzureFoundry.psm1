#Requires -Version 7.4

# --- Module state -------------------------------------------------------------------------------
# Active connection set by Connect-AzFoundry (AzFoundryConnection), cleared by Disconnect-AzFoundry.
$script:AzFoundryConnection = $null

# Entra ID token cache for data-plane calls: @{ Token = [SecureString]; ExpiresOn = [datetimeoffset] }.
$script:AzFoundryTokenCache = $null

# Entra scope for data-plane tokens (spec section 2.1: both cognitiveservices and ai.azure.com work).
$script:AzFoundryTokenScope = 'https://cognitiveservices.azure.com/.default'

# ARM management plane (spec sections 2.1 and 4.2). Sovereign clouds are out of scope for v1.
$script:AzFoundryArmBaseUri    = 'https://management.azure.com'
$script:AzFoundryArmApiVersion = '2025-06-01'

# HTTP behaviour (spec section 8).
$script:AzFoundryMaxRetry          = 3
$script:AzFoundryDefaultTimeoutSec = 120

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
