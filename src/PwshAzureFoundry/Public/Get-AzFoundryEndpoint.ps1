#Requires -Version 7.4

function Get-AzFoundryEndpoint {
    <#
    .SYNOPSIS
        Gets the endpoints (and optionally the keys) of an Azure AI Foundry resource.
    .DESCRIPTION
        Calls GET .../accounts/{account} on Azure Resource Manager (needs Az.Accounts and Connect-AzAccount) and
        returns one PwshAzureFoundry.Endpoint object:

          Endpoint            the Foundry host (https://<account>.services.ai.azure.com), for Connect-AzFoundry
          OpenAIEndpoint      the OpenAI host (https://<account>.openai.azure.com)
          ChatCompletionsUri, EmbeddingsUri, DecisionUri   the data-plane routes the module calls
          Endpoints           every entry of properties.endpoints (about 70 named endpoints)
          AccountName, ResourceGroupName, SubscriptionId, Location, Kind, DisableLocalAuth, PublicNetworkAccess

        -IncludeKey adds Key1 and Key2 as SecureString (POST .../listKeys). Keys are never written to the
        verbose or debug output.
    .PARAMETER IncludeKey
        Add the resource keys (Key1, Key2) as SecureString.
    .PARAMETER ResourceGroupName
        Resource group of the resource. Defaults to the resource of Connect-AzFoundry -ResourceGroupName.
    .PARAMETER AccountName
        Name of the resource. Defaults to the resource of Connect-AzFoundry -AccountName.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the session, then to the current Az context.
    .EXAMPLE
        Get-AzFoundryEndpoint -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry'

        Shows the endpoints of the resource.
    .EXAMPLE
        $endpoint = Get-AzFoundryEndpoint -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry' -IncludeKey
        Connect-AzFoundry -Endpoint $endpoint.Endpoint -ApiKey $endpoint.Key1

        Connects to the data plane with the first key.
    .LINK
        Connect-AzFoundry
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Endpoint')]
    param(
        [switch]$IncludeKey,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[-\w.()]{0,89}[-\w()]$')]
        [string]$ResourceGroupName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId
    )

    process {
        try {
            $target = Resolve-AzFoundryArmTarget -ResourceGroupName $ResourceGroupName -AccountName $AccountName `
                -SubscriptionId $SubscriptionId
            $account = Invoke-AzFoundryArmRequest -Path $target.Path
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $properties = $account.properties
        $endpoints = [ordered]@{}
        if ($properties -and $properties.PSObject.Properties['endpoints'] -and $properties.endpoints) {
            foreach ($property in $properties.endpoints.PSObject.Properties) {
                $endpoints[$property.Name] = [string]$property.Value
            }
        }
        $pick = {
            param([string[]]$Names)
            foreach ($entry in $Names) {
                if ($endpoints.Contains($entry) -and $endpoints[$entry]) {
                    return ConvertTo-AzFoundryEndpoint -Endpoint $endpoints[$entry]
                }
            }
        }
        $foundry = & $pick 'AI Foundry API'
        $openAI = & $pick 'OpenAI Language Model Instance API'
        if (-not $foundry -and $properties.endpoint) {
            $foundry = ConvertTo-AzFoundryEndpoint -Endpoint ([string]$properties.endpoint)
        }
        if (-not $openAI -and $foundry) {
            $openAI = ConvertTo-AzFoundryEndpoint -Endpoint $foundry -HostForm OpenAI
        }
        $base = if ($foundry) { $foundry } else { $openAI }

        $result = [ordered]@{
            PSTypeName          = 'PwshAzureFoundry.Endpoint'
            AccountName         = $target.AccountName
            ResourceGroupName   = $target.ResourceGroupName
            SubscriptionId      = $target.SubscriptionId
            Location            = [string]$account.location
            Kind                = [string]$account.kind
            Endpoint            = $foundry
            OpenAIEndpoint      = $openAI
            ChatCompletionsUri  = if ($base) { "$base/openai/v1/chat/completions" }
            EmbeddingsUri       = if ($base) { "$base/openai/v1/embeddings" }
            DecisionUri         = if ($base) { "$base/providers/microsoft/v1/systemone" }
            DisableLocalAuth    = [bool]($properties -and $properties.PSObject.Properties['disableLocalAuth'] -and
                $properties.disableLocalAuth)
            PublicNetworkAccess = if ($properties -and $properties.PSObject.Properties['publicNetworkAccess']) {
                [string]$properties.publicNetworkAccess
            }
            Endpoints           = $endpoints
        }

        if ($IncludeKey) {
            if ($result.DisableLocalAuth) {
                Write-Warning "Key authentication is disabled on $($target.AccountName); the keys do not work."
            }
            Write-Verbose "Reading the keys of $($target.AccountName) (listKeys)."
            try {
                $keys = Invoke-AzFoundryArmRequest -Path "$($target.Path)/listKeys" -Method POST
            } catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
            $result['Key1'] = if ($keys.key1) { ConvertTo-AzFoundrySecureString -String $keys.key1 }
            $result['Key2'] = if ($keys.key2) { ConvertTo-AzFoundrySecureString -String $keys.key2 }
            $keys = $null
        }

        [pscustomobject]$result
    }
}
