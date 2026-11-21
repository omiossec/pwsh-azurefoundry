#Requires -Version 7.4

function Get-AzFoundryModel {
    <#
    .SYNOPSIS
        Lists the models available to deploy on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls GET .../accounts/{account}/models on Azure Resource Manager (needs Az.Accounts and
        Connect-AzAccount). The list is the catalogue for this resource (region, subscription), not the deployed
        models: use Get-AzFoundryDeployment for those.

        By default the cmdlet returns one version per model (the default version, or else the latest) and leaves
        out deprecated models (lifecycle status Deprecated, or a deprecation date that has passed). Use
        -AllVersions and -IncludeDeprecated to see them.

        Output: PwshAzureFoundry.Model objects (Name, Version, Format, Publisher, LifecycleStatus, DeprecationDate,
        Skus, Tasks, Capabilities...). Pipe them to New-AzFoundryDeployment to deploy a model.
    .PARAMETER Name
        Model name; wildcards allowed (for example 'gpt-*').
    .PARAMETER Format
        Model format, also called publisher (OpenAI, Mistral AI, Cohere, Microsoft...); wildcards allowed.
    .PARAMETER Sku
        Keep the models that can be deployed with this SKU (GlobalStandard, Standard, DataZoneStandard...).
    .PARAMETER Task
        Keep the models with all these capabilities, for example chatCompletion, embeddings or decision.
    .PARAMETER AllVersions
        Return every version of each model instead of the default or latest one.
    .PARAMETER IncludeDeprecated
        Include deprecated models.
    .PARAMETER ResourceGroupName
        Resource group of the resource. Defaults to the resource of Connect-AzFoundry -ResourceGroupName.
    .PARAMETER AccountName
        Name of the resource. Defaults to the resource of Connect-AzFoundry -AccountName.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the session, then to the current Az context.
    .EXAMPLE
        Get-AzFoundryModel -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry' -Task chatCompletion

        Lists the chat models that can be deployed on the resource.
    .EXAMPLE
        Get-AzFoundryModel -Name 'text-embedding-3-small' | New-AzFoundryDeployment -Capacity 1

        Deploys the latest version of a model on the session resource.
    .LINK
        Get-AzFoundryDeployment
    .LINK
        New-AzFoundryDeployment
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Model')]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string]$Name,

        [Alias('Publisher')]
        [ValidateNotNullOrEmpty()]
        [SupportsWildcards()]
        [string]$Format,

        [ValidateNotNullOrEmpty()]
        [string]$Sku,

        [ValidateNotNullOrEmpty()]
        [string[]]$Task,

        [switch]$AllVersions,

        [switch]$IncludeDeprecated,

        [ValidatePattern('^[-\w.()]{0,89}[-\w()]$')]
        [string]$ResourceGroupName,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId
    )

    try {
        $target = Resolve-AzFoundryArmTarget -ResourceGroupName $ResourceGroupName -AccountName $AccountName `
            -SubscriptionId $SubscriptionId
        $now = Get-AzFoundryUtcNow
        $models = @(Invoke-AzFoundryArmRequest -Path "$($target.Path)/models" |
                ConvertTo-AzFoundryModel -Target $target -Now $now)
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
    Write-Verbose "$($models.Count) model version(s) in the catalogue of $($target.AccountName)."

    $selected = $models | Where-Object {
        (-not $Name -or $_.Name -like $Name) -and
        (-not $Format -or $_.Format -like $Format -or $_.Publisher -like $Format) -and
        (-not $Sku -or $_.Skus -contains $Sku) -and
        ($IncludeDeprecated -or -not $_.IsDeprecated)
    }
    if ($Task) {
        $selected = $selected | Where-Object {
            $model = $_
            -not ($Task | Where-Object { $model.Tasks -notcontains $_ })
        }
    }
    if (-not $AllVersions) {
        $selected = $selected | Select-AzFoundryLatestModel
    }
    $selected = @($selected | Sort-Object -Property Format, Name, Version)

    if ($selected.Count -eq 0 -and $Name -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        $hidden = @($models | Where-Object { $_.Name -like $Name -and $_.IsDeprecated })
        $hint = if ($hidden -and -not $IncludeDeprecated) {
            "The model is deprecated: add -IncludeDeprecated to see it."
        } else {
            "Run Get-AzFoundryModel without -Name to list the catalogue of $($target.AccountName)."
        }
        $PSCmdlet.WriteError((New-AzFoundryErrorRecord `
                    -Message "No model '$Name' matches on $($target.AccountName)." `
                    -ErrorId 'AzFoundryModelNotFound' -Category ObjectNotFound -TargetObject $Name `
                    -ExceptionType ([System.Management.Automation.ItemNotFoundException]) -RecommendedAction $hint))
        return
    }
    foreach ($model in $selected) {
        $model
    }
}
