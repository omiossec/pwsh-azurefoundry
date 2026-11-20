#Requires -Version 7.4

function ConvertTo-AzFoundryDeployment {
    <#
    .SYNOPSIS
        Converts an ARM deployment (Microsoft.CognitiveServices/accounts/deployments) into a
        PwshAzureFoundry.Deployment object.
    .DESCRIPTION
        Output properties (spec section 5.3): Name, ModelName, Version, Format, Sku, Capacity, ProvisioningState,
        RaiPolicy, Capabilities (ordered name -> value), CreatedAt and ModifiedAt (DateTimeOffset), Id,
        SubscriptionId, ResourceGroupName, AccountName.

        Name binds to -Model of Invoke-AzFoundryChat (through its Name alias) and to -Name of
        Remove-AzFoundryDeployment, and the resource properties bind to -ResourceGroupName, -AccountName and
        -SubscriptionId. The catalogue model is ModelName, not Model: a Model property would bind to -Model of
        Invoke-AzFoundryChat before the Name alias, and send the model name instead of the deployment name.
    .PARAMETER InputObject
        The ARM deployment.
    .PARAMETER Target
        The resource (Resolve-AzFoundryArmTarget), copied to the output.
    .EXAMPLE
        $items | ConvertTo-AzFoundryDeployment -Target $target
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Deployment')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [object]$Target
    )

    process {
        $get = {
            param([object]$Object, [string]$Name)
            if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name }
        }
        $properties = & $get $InputObject 'properties'
        $model = & $get $properties 'model'
        $sku = & $get $InputObject 'sku'
        $systemData = & $get $InputObject 'systemData'

        $capabilities = [ordered]@{}
        $given = & $get $properties 'capabilities'
        if ($given) {
            foreach ($property in $given.PSObject.Properties) {
                $capabilities[$property.Name] = [string]$property.Value
            }
        }

        [pscustomobject]@{
            PSTypeName        = 'PwshAzureFoundry.Deployment'
            Name              = [string](& $get $InputObject 'name')
            ModelName         = [string](& $get $model 'name')
            Version           = [string](& $get $model 'version')
            Format            = [string](& $get $model 'format')
            Sku               = [string](& $get $sku 'name')
            Capacity          = & $get $sku 'capacity'
            ProvisioningState = [string](& $get $properties 'provisioningState')
            RaiPolicy         = [string](& $get $properties 'raiPolicyName')
            Capabilities      = $capabilities
            CreatedAt         = ConvertTo-AzFoundryDateTimeOffset -Value (& $get $systemData 'createdAt')
            ModifiedAt        = ConvertTo-AzFoundryDateTimeOffset -Value (& $get $systemData 'lastModifiedAt')
            Id                = [string](& $get $InputObject 'id')
            SubscriptionId    = $Target.SubscriptionId
            ResourceGroupName = $Target.ResourceGroupName
            AccountName       = $Target.AccountName
        }
    }
}
