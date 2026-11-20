#Requires -Version 7.4
# Shared by the integration tests. Dot-source it in BeforeDiscovery (for the -Skip conditions) and in BeforeAll.
#
# Settings come from environment variables (see test/Integration/README.md). Nothing here prints a key.

function Get-ItValue {
    param([string]$Value, [string]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { $Default } else { $Value }
}

function Get-ItSetting {
    $setting = [ordered]@{
        Endpoint        = $env:AZURE_FOUNDRY_ENDPOINT
        HasApiKey       = -not [string]::IsNullOrWhiteSpace($env:AZURE_FOUNDRY_API_KEY)
        ResourceGroup   = $env:AZURE_FOUNDRY_RG
        Account         = $env:AZURE_FOUNDRY_ACCOUNT
        SubscriptionId  = $env:AZURE_FOUNDRY_SUBSCRIPTION_ID
        ChatModel       = Get-ItValue $env:AZURE_FOUNDRY_CHAT_MODEL 'Mistral-Large-3'
        DecisionModel   = Get-ItValue $env:AZURE_FOUNDRY_DECISION_MODEL 'Decision-1.1'
        EmbeddingModel  = Get-ItValue $env:AZURE_FOUNDRY_EMBEDDING_MODEL 'text-embedding-3-small'
        AsyncModel      = $env:AZURE_FOUNDRY_ASYNC_MODEL
        HasKey          = $false
        HasArm          = $false
        HasAzContext    = $false
        SkipKeyReason   = 'Set AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY.'
        SkipArmReason   = 'Set AZURE_FOUNDRY_RG and AZURE_FOUNDRY_ACCOUNT, and run Connect-AzAccount.'
    }
    $setting.HasKey = -not [string]::IsNullOrWhiteSpace($setting.Endpoint) -and $setting.HasApiKey

    if (Get-Module -ListAvailable -Name Az.Accounts) {
        Import-Module Az.Accounts -ErrorAction SilentlyContinue
        $context = Get-AzContext -ErrorAction SilentlyContinue
        $setting.HasAzContext = [bool]($context -and $context.Account)
    }
    $setting.HasArm = $setting.HasAzContext -and
    -not [string]::IsNullOrWhiteSpace($setting.ResourceGroup) -and
    -not [string]::IsNullOrWhiteSpace($setting.Account)
    [pscustomobject]$setting
}

function Import-ItModule {
    Get-Module PwshAzureFoundry | Remove-Module -Force
    Import-Module (Join-Path $PSScriptRoot '../../src/PwshAzureFoundry/PwshAzureFoundry.psd1') -Force
}

# The API key from the environment, as a SecureString (never as a string variable in the tests).
function Get-ItApiKey {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'The key comes from an environment variable, which is plain text by nature.')]
    [CmdletBinding()]
    param()
    ConvertTo-SecureString -String $env:AZURE_FOUNDRY_API_KEY -AsPlainText -Force
}

# A deployment name unique to this run. Every name starts with 'pwshit-' so leftovers are easy to spot.
function Get-ItDeploymentName {
    param([Parameter(Mandatory)][string]$Purpose)
    'pwshit-{0}-{1:yyyyMMddHHmmss}' -f $Purpose, [datetime]::UtcNow
}

# The management parameters from the environment, for splatting.
function Get-ItArmTarget {
    $target = @{ ResourceGroupName = $env:AZURE_FOUNDRY_RG; AccountName = $env:AZURE_FOUNDRY_ACCOUNT }
    if ($env:AZURE_FOUNDRY_SUBSCRIPTION_ID) {
        $target['SubscriptionId'] = $env:AZURE_FOUNDRY_SUBSCRIPTION_ID
    }
    $target
}

# Deletes the deployments created by a test file, whatever happened before. Never throws.
function Remove-ItDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param([string[]]$Name)
    $target = Get-ItArmTarget
    foreach ($item in $Name) {
        if (-not $PSCmdlet.ShouldProcess($item, 'Delete the test deployment')) {
            continue
        }
        try {
            Remove-AzFoundryDeployment @target -Name $item -Confirm:$false -ErrorAction Stop
            Write-Information "Cleanup: deleted $item." -InformationAction Continue
        } catch {
            Write-Warning "Cleanup: could not delete $item ($($_.Exception.Message)). Delete it by hand."
        }
    }
    try {
        $leftovers = @(Get-AzFoundryDeployment @target -Name 'pwshit-*' -ErrorAction Stop)
        if ($leftovers) {
            Write-Warning ('Deployments from integration runs are still on the resource: ' +
                ($leftovers.Name -join ', ') + '. Delete them if no run is in progress.')
        }
    } catch {
        Write-Warning "Cleanup: could not list the deployments ($($_.Exception.Message))."
    }
}
