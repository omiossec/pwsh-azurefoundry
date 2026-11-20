#Requires -Version 7.4

function ConvertTo-AzFoundryModel {
    <#
    .SYNOPSIS
        Converts an item of GET .../accounts/{a}/models into a PwshAzureFoundry.Model object.
    .DESCRIPTION
        The ARM item is flat (spec section 2.1): format, name, version, isDefaultVersion, skus[], capabilities,
        lifecycleStatus, deprecation.inference. Output properties:

        Name, Version, Format, Publisher (publisher, or format when missing), IsDefaultVersion, LifecycleStatus,
        DeprecationDate (DateTimeOffset or $null), IsDeprecated (lifecycleStatus Deprecated, or the deprecation
        date has passed), Skus (names), SkuCapacity (sku name -> { Default, Maximum }), MaxCapacity,
        Capabilities (ordered name -> value, as strings), Tasks (the capabilities whose value is 'true'),
        SubscriptionId, ResourceGroupName, AccountName.
    .PARAMETER InputObject
        The ARM item.
    .PARAMETER Target
        The resource (Resolve-AzFoundryArmTarget), copied to the output.
    .PARAMETER Now
        Current time, for IsDeprecated.
    .EXAMPLE
        $items | ConvertTo-AzFoundryModel -Target $target -Now (Get-AzFoundryUtcNow)
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Model')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [object]$Target,

        [Parameter(Mandatory)]
        [datetimeoffset]$Now
    )

    process {
        $item = $InputObject
        # Older api-versions nest the model under 'model'.
        if ($item.PSObject.Properties['model'] -and $item.model -and -not $item.PSObject.Properties['name']) {
            $item = $item.model
        }
        $get = {
            param([object]$Object, [string]$Name)
            if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name }
        }

        $deprecation = & $get $item 'deprecation'
        $deprecationDate = ConvertTo-AzFoundryDateTimeOffset -Value (& $get $deprecation 'inference')
        $lifecycle = [string](& $get $item 'lifecycleStatus')
        $isDeprecated = $lifecycle -eq 'Deprecated' -or ($null -ne $deprecationDate -and $deprecationDate -le $Now)

        $capabilities = [ordered]@{}
        $tasks = [System.Collections.Generic.List[string]]::new()
        $given = & $get $item 'capabilities'
        if ($given) {
            foreach ($property in $given.PSObject.Properties) {
                $capabilities[$property.Name] = [string]$property.Value
                if ([string]$property.Value -eq 'true') {
                    $tasks.Add($property.Name)
                }
            }
        }

        $skus = [System.Collections.Generic.List[string]]::new()
        $skuCapacity = [ordered]@{}
        foreach ($sku in @(& $get $item 'skus')) {
            if (-not $sku) {
                continue
            }
            $skus.Add([string]$sku.name)
            $capacity = & $get $sku 'capacity'
            $skuCapacity[[string]$sku.name] = [pscustomobject]@{
                Default = & $get $capacity 'default'
                Maximum = & $get $capacity 'maximum'
            }
        }

        $format = [string](& $get $item 'format')
        $publisher = [string](& $get $item 'publisher')
        [pscustomobject]@{
            PSTypeName        = 'PwshAzureFoundry.Model'
            Name              = [string](& $get $item 'name')
            Version           = [string](& $get $item 'version')
            Format            = $format
            Publisher         = if ($publisher) { $publisher } else { $format }
            IsDefaultVersion  = [bool](& $get $item 'isDefaultVersion')
            LifecycleStatus   = $lifecycle
            DeprecationDate   = $deprecationDate
            IsDeprecated      = $isDeprecated
            Skus              = $skus.ToArray()
            SkuCapacity       = $skuCapacity
            MaxCapacity       = & $get $item 'maxCapacity'
            Capabilities      = $capabilities
            Tasks             = $tasks.ToArray()
            SubscriptionId    = $Target.SubscriptionId
            ResourceGroupName = $Target.ResourceGroupName
            AccountName       = $Target.AccountName
        }
    }
}
