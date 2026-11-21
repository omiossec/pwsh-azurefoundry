#Requires -Version 7.4

function New-AzFoundryDeployment {
    <#
    .SYNOPSIS
        Deploys a model on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls PUT .../accounts/{account}/deployments/{name} on Azure Resource Manager (needs Az.Accounts and
        Connect-AzAccount).

        The model comes from -ModelName, or from a PwshAzureFoundry.Model piped from Get-AzFoundryModel. Without
        -ModelVersion or -ModelFormat, the cmdlet reads the catalogue of the resource and takes the default (or
        latest) version and the format of the model, and checks that -SkuName is available for the model.

        OpenAI models deploy at once; partner models (Mistral, Cohere...) take about a minute. Without -NoWait the
        cmdlet waits until the deployment has succeeded, then sends a minimal request until the deployment
        answers on the data plane (about 20 s after success; -SkipReadinessCheck turns this off). The readiness
        check of a chat, embeddings or decision model uses a few tokens. It uses the Connect-AzFoundry session when
        it points to the same resource; otherwise it follows the session's auth mode (an Entra ID session never
        reads the account keys), and without a session it reads the key with listKeys.

        The cmdlet refuses to replace an existing deployment with the same name.

        Output: the PwshAzureFoundry.Deployment.
    .PARAMETER ModelName
        Name of the model in the catalogue, for example text-embedding-3-small (see Get-AzFoundryModel).
    .PARAMETER InputObject
        A PwshAzureFoundry.Model from Get-AzFoundryModel. Gives the model name, version and format, and the
        resource unless -ResourceGroupName and -AccountName are given.
    .PARAMETER Name
        Deployment name, which the inference cmdlets take as -Model. Defaults to the model name.
    .PARAMETER ModelVersion
        Model version. Defaults to the default (or latest) version in the catalogue.
    .PARAMETER ModelFormat
        Model format (OpenAI, Mistral AI, Cohere, Microsoft...). Defaults to the format in the catalogue.
    .PARAMETER SkuName
        Deployment type: GlobalStandard (default), Standard, DataZoneStandard...
    .PARAMETER Capacity
        Capacity units, 1 by default. For GlobalStandard, N units are N requests and N x 1000 tokens per minute.
        The default of the catalogue (often thousands of units) is not used: it is usually above the quota of the
        subscription.
    .PARAMETER RaiPolicyName
        Content filter (RAI policy) name. Defaults to the resource default (Microsoft.DefaultV2).
    .PARAMETER NoWait
        Return as soon as ARM accepts the request (the deployment may still be Creating).
    .PARAMETER SkipReadinessCheck
        Do not wait for the deployment to answer on the data plane.
    .PARAMETER ResourceGroupName
        Resource group of the resource. Defaults to the piped model, then to the resource of Connect-AzFoundry.
    .PARAMETER AccountName
        Name of the resource. Defaults to the piped model, then to the resource of Connect-AzFoundry.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the piped model, the session, then the current Az context.
    .EXAMPLE
        New-AzFoundryDeployment -ModelName 'text-embedding-3-small' -Capacity 1 -WhatIf

        Shows the version, format, SKU and capacity that would be deployed, without deploying.
    .EXAMPLE
        Get-AzFoundryModel -Name 'Mistral-Large-3' | New-AzFoundryDeployment -Name 'chat' -Capacity 20

        Deploys the latest version of Mistral-Large-3 as 'chat' and waits until it answers.
    .LINK
        Get-AzFoundryModel
    .LINK
        Get-AzFoundryDeployment
    .LINK
        Remove-AzFoundryDeployment
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ModelName')]
    [OutputType('PwshAzureFoundry.Deployment')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ModelName')]
        [ValidateNotNullOrEmpty()]
        [string]$ModelName,

        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InputObject')]
        [PSTypeName('PwshAzureFoundry.Model')]
        [object]$InputObject,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
        [string]$Name,

        [Parameter(ParameterSetName = 'ModelName')]
        [ValidateNotNullOrEmpty()]
        [string]$ModelVersion,

        [Parameter(ParameterSetName = 'ModelName')]
        [ValidateNotNullOrEmpty()]
        [string]$ModelFormat,

        [ArgumentCompletions('GlobalStandard', 'Standard', 'DataZoneStandard', 'GlobalProvisionedManaged',
            'DataZoneProvisionedManaged', 'ProvisionedManaged', 'GlobalBatch', 'DataZoneBatch', 'DeveloperTier')]
        [ValidateNotNullOrEmpty()]
        [string]$SkuName = 'GlobalStandard',

        [ValidateRange(1, 1000000)]
        [int]$Capacity,

        [ValidateNotNullOrEmpty()]
        [string]$RaiPolicyName,

        [switch]$NoWait,

        [switch]$SkipReadinessCheck,

        [ValidatePattern('^[-\w.()]{0,89}[-\w()]$')]
        [string]$ResourceGroupName,

        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId
    )

    process {
        try {
            # The resource: parameters, then the piped model, then the session.
            $group = $ResourceGroupName
            $account = $AccountName
            $subscription = $SubscriptionId
            if ($InputObject -and -not $group -and -not $account) {
                $group = $InputObject.ResourceGroupName
                $account = $InputObject.AccountName
                if (-not $subscription) {
                    $subscription = $InputObject.SubscriptionId
                }
            }
            $target = Resolve-AzFoundryArmTarget -ResourceGroupName $group -AccountName $account `
                -SubscriptionId $subscription

            # The model: the piped object, the parameters, or the catalogue.
            $catalogueEntry = $null
            if ($InputObject) {
                $catalogueEntry = $InputObject
                $model = [ordered]@{
                    format  = [string]$InputObject.Format
                    name    = [string]$InputObject.Name
                    version = [string]$InputObject.Version
                }
            } else {
                $model = [ordered]@{ format = $ModelFormat; name = $ModelName; version = $ModelVersion }
                if (-not $ModelVersion -or -not $ModelFormat) {
                    Write-Verbose "Reading the catalogue of $($target.AccountName) for $ModelName."
                    $now = Get-AzFoundryUtcNow
                    $candidates = @(Invoke-AzFoundryArmRequest -Path "$($target.Path)/models" |
                            ConvertTo-AzFoundryModel -Target $target -Now $now |
                            Where-Object {
                                $_.Name -eq $ModelName -and
                                (-not $ModelFormat -or $_.Format -eq $ModelFormat) -and
                                (-not $ModelVersion -or $_.Version -eq $ModelVersion)
                            })
                    $formats = @($candidates.Format | Sort-Object -Unique)
                    if ($candidates.Count -eq 0) {
                        if (-not $ModelVersion -or -not $ModelFormat) {
                            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                                        -Message "No model '$ModelName' in the catalogue of $($target.AccountName)." `
                                        -ErrorId 'AzFoundryModelNotFound' -Category ObjectNotFound `
                                        -TargetObject $ModelName `
                                        -ExceptionType ([System.Management.Automation.ItemNotFoundException]) `
                                        -RecommendedAction 'Run Get-AzFoundryModel to list the models and versions.'))
                        }
                        Write-Verbose 'The model is not in the catalogue; using the given version and format.'
                    } elseif ($formats.Count -gt 1) {
                        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                                    -Message ("The model '$ModelName' exists in several formats: " +
                                    ($formats -join ', ') + '.') `
                                    -ErrorId 'AzFoundryModelAmbiguous' -Category InvalidArgument `
                                    -TargetObject $ModelName -ExceptionType ([System.ArgumentException]) `
                                    -RecommendedAction 'Add -ModelFormat.'))
                    } else {
                        $catalogueEntry = $candidates | Select-AzFoundryLatestModel
                        $model.format = $catalogueEntry.Format
                        $model.version = $catalogueEntry.Version
                    }
                }
            }
            $deploymentName = if ($Name) { $Name } else { $model.name }
            if (-not $Name) {
                if ($deploymentName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
                    $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                                -Message "The model name '$deploymentName' is not a valid deployment name." `
                                -ErrorId 'AzFoundryDeploymentNameInvalid' -Category InvalidArgument `
                                -TargetObject $deploymentName -ExceptionType ([System.ArgumentException]) `
                                -RecommendedAction 'Add -Name (letters, digits, dot, dash and underscore).'))
                }
            }

            if ($catalogueEntry) {
                if ($catalogueEntry.IsDeprecated) {
                    Write-Warning ("$($model.name) $($model.version) is deprecated" +
                        $(if ($catalogueEntry.DeprecationDate) {
                                ' (inference until {0:yyyy-MM-dd})' -f $catalogueEntry.DeprecationDate
                            }) + '.')
                }
                if ($catalogueEntry.Skus -and $catalogueEntry.Skus -notcontains $SkuName) {
                    $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                                -Message ("$($model.name) $($model.version) cannot be deployed as $SkuName on " +
                                "$($target.AccountName). Available: $($catalogueEntry.Skus -join ', ').") `
                                -ErrorId 'AzFoundrySkuNotAvailable' -Category InvalidArgument -TargetObject $SkuName `
                                -ExceptionType ([System.ArgumentException]) `
                                -RecommendedAction 'Pass one of the available SKUs with -SkuName.'))
                }
            }
            $units = if ($PSBoundParameters.ContainsKey('Capacity')) { $Capacity } else { 1 }
            $limit = if ($catalogueEntry -and $catalogueEntry.SkuCapacity -and
                $catalogueEntry.SkuCapacity.Contains($SkuName)) {
                $catalogueEntry.SkuCapacity[$SkuName].Maximum
            }
            if ($limit -and $units -gt $limit) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "The maximum capacity of $($model.name) as $SkuName is $limit (got $units)." `
                            -ErrorId 'AzFoundryCapacityTooHigh' -Category InvalidArgument -TargetObject $units `
                            -ExceptionType ([System.ArgumentException]) `
                            -RecommendedAction "Pass -Capacity $limit or less."))
            }

            # Never replace an existing deployment (PUT would update it in place).
            $existing = @(Invoke-AzFoundryArmRequest -Path "$($target.Path)/deployments" | Where-Object {
                    [string]::Equals([string]$_.name, $deploymentName, [StringComparison]::OrdinalIgnoreCase)
                })
            if ($existing) {
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                            -Message "A deployment named '$deploymentName' already exists on $($target.AccountName)." `
                            -ErrorId 'AzFoundryDeploymentExists' -Category ResourceExists `
                            -TargetObject $deploymentName -ExceptionType ([System.InvalidOperationException]) `
                            -RecommendedAction 'Choose another -Name, or delete it with Remove-AzFoundryDeployment.'))
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $description = '{0} model {1} version {2} ({3}, capacity {4})' -f $model.format, $model.name,
        $model.version, $SkuName, $units
        if (-not $PSCmdlet.ShouldProcess("$deploymentName on $($target.AccountName)", "Deploy $description")) {
            return
        }

        $properties = [ordered]@{ model = $model }
        if ($RaiPolicyName) {
            $properties['raiPolicyName'] = $RaiPolicyName
        }
        $body = [ordered]@{
            sku        = [ordered]@{ name = $SkuName; capacity = $units }
            properties = $properties
        }
        Write-Verbose "Deploying $deploymentName on $($target.AccountName): $description."
        try {
            $response = Invoke-AzFoundryArmRequest -Method PUT -Body $body -NoWait:$NoWait `
                -Path ('{0}/deployments/{1}' -f $target.Path, [uri]::EscapeDataString($deploymentName))
        } catch {
            if ("$($_.Exception.Message)" -match 'marketplace|agreement|terms of use') {
                $hint = 'Deploy the model once in the Foundry portal to accept its terms, ' +
                'and check that the subscription allows Azure Marketplace purchases.'
                $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord -Exception $_.Exception `
                            -Message $_.Exception.Message -ErrorId 'AzFoundryMarketplaceTerms' `
                            -Category $_.CategoryInfo.Category -TargetObject $model.name -RecommendedAction $hint))
            }
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $deployment = $response | ConvertTo-AzFoundryDeployment -Target $target
        if ($NoWait) {
            Write-Verbose ("Not waiting (-NoWait): state $($deployment.ProvisioningState). " +
                'Follow it with Get-AzFoundryDeployment.')
            return $deployment
        }
        if ($deployment.ProvisioningState -ne 'Succeeded') {
            Write-Warning "$deploymentName ended in state $($deployment.ProvisioningState)."
            return $deployment
        }
        if (-not $SkipReadinessCheck) {
            $tasks = @($deployment.Capabilities.Keys | Where-Object { $deployment.Capabilities[$_] -eq 'true' })
            if (-not $tasks -and $catalogueEntry) {
                $tasks = @($catalogueEntry.Tasks)
            }
            $null = Wait-AzFoundryDeploymentReady -Target $target -Name $deploymentName -Task $tasks
        }
        $deployment
    }
}
