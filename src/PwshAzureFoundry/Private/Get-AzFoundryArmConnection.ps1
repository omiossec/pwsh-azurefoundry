#Requires -Version 7.4

function Get-AzFoundryArmConnection {
    <#
    .SYNOPSIS
        Builds a connection from the ARM description of a Foundry resource.
    .DESCRIPTION
        Reads the resource (GET .../accounts/{name}) and takes its endpoint from properties.endpoints
        ('AI Foundry API', then 'OpenAI Language Model Instance API', then properties.endpoint). Without
        -UseEntraId it reads key1 with POST .../listKeys and wraps it in a SecureString at once. A resource
        with local (key) authentication disabled needs -UseEntraId.
    .PARAMETER ResourceGroupName
        Resource group of the resource.
    .PARAMETER AccountName
        Name of the resource.
    .PARAMETER SubscriptionId
        Subscription of the resource. Defaults to the subscription of the current Az context.
    .PARAMETER UseEntraId
        Use Entra ID authentication; listKeys is not called.
    .EXAMPLE
        $connection = Get-AzFoundryArmConnection -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry'
    #>
    [CmdletBinding()]
    [OutputType([AzFoundryConnection])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$AccountName,

        [AllowEmptyString()]
        [string]$SubscriptionId,

        [switch]$UseEntraId
    )

    $subscription = Resolve-AzFoundrySubscriptionId -SubscriptionId $SubscriptionId
    $path = Get-AzFoundryArmAccountPath -SubscriptionId $subscription -ResourceGroupName $ResourceGroupName `
        -AccountName $AccountName

    Write-Verbose "Reading the endpoint of $AccountName from Azure Resource Manager."
    $account = Invoke-AzFoundryArmRequest -Path $path
    $properties = $account.properties

    $endpoint = $null
    if ($properties.endpoints) {
        foreach ($name in 'AI Foundry API', 'OpenAI Language Model Instance API') {
            $property = $properties.endpoints.PSObject.Properties[$name]
            if ($property -and $property.Value) {
                $endpoint = [string]$property.Value
                break
            }
        }
    }
    if (-not $endpoint) {
        $endpoint = [string]$properties.endpoint
    }
    if (-not $endpoint) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "The resource $AccountName has no endpoint." `
                    -ErrorId 'AzFoundryEndpointMissing' -Category InvalidResult -TargetObject $AccountName `
                    -ExceptionType ([System.InvalidOperationException]) `
                    -RecommendedAction 'Check that the resource is an Azure AI Foundry (AIServices) resource.'))
    }
    if ($account.kind -and $account.kind -notin 'AIServices', 'OpenAI') {
        Write-Warning "$AccountName is a '$($account.kind)' resource, not an Azure AI Foundry (AIServices) resource."
    }

    $normalised = ConvertTo-AzFoundryEndpoint -Endpoint $endpoint
    $authMode = if ($UseEntraId) { 'EntraId' } else { 'ApiKey' }
    $connection = [AzFoundryConnection]::new($normalised, $authMode)
    $connection.SubscriptionId = $subscription
    $connection.ResourceGroupName = $ResourceGroupName
    $connection.AccountName = $AccountName

    if (-not $UseEntraId) {
        if ($properties.disableLocalAuth -eq $true) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "Key authentication is disabled on $AccountName." `
                        -ErrorId 'AzFoundryLocalAuthDisabled' -Category PermissionDenied -TargetObject $AccountName `
                        -ExceptionType ([System.InvalidOperationException]) `
                        -RecommendedAction 'Add -UseEntraId to connect with an Entra ID token.'))
        }
        Write-Verbose "Reading the key of $AccountName (listKeys)."
        $keys = Invoke-AzFoundryArmRequest -Path "$path/listKeys" -Method POST
        if (-not $keys -or [string]::IsNullOrEmpty($keys.key1)) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "listKeys returned no key for $AccountName." `
                        -ErrorId 'AzFoundryKeyMissing' -Category InvalidResult -TargetObject $AccountName `
                        -ExceptionType ([System.InvalidOperationException]) `
                        -RecommendedAction 'Add -UseEntraId, or connect with -Endpoint and -ApiKey.'))
        }
        $connection.ApiKey = ConvertTo-AzFoundrySecureString -String $keys.key1
        $keys = $null
    }

    $connection
}
