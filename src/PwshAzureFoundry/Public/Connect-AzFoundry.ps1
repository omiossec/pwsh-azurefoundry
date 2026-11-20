#Requires -Version 7.4

function Connect-AzFoundry {
    <#
    .SYNOPSIS
        Connects the session to an Azure AI Foundry resource.
    .DESCRIPTION
        Sets the endpoint and the authentication used by the data-plane cmdlets of this session. There are
        three ways to connect:

        - ApiKey: -Endpoint and -ApiKey (a SecureString). Az.Accounts is not needed.
        - EntraId: -Endpoint and -UseEntraId. Requests use an Entra ID token from Az.Accounts
          (run Connect-AzAccount first). The token is checked when you connect.
        - Arm: -ResourceGroupName and -AccountName (and -SubscriptionId, which defaults to the subscription of
          the current Az context). The endpoint is read from the resource and the key is read with ARM
          listKeys, so no key is copied by hand. Add -UseEntraId to use an Entra ID token instead of the key.
          The resource group and subscription are kept for the management cmdlets.

        Either host form is accepted (https://<name>.services.ai.azure.com or https://<name>.openai.azure.com);
        any path (/openai/v1, /) is removed. Only https endpoints are allowed.

        Connecting again replaces the current connection. The key stays a SecureString and is never shown,
        logged or put in an error message.
    .PARAMETER Endpoint
        Endpoint of the Foundry resource, for example https://<name>.services.ai.azure.com.
    .PARAMETER ApiKey
        API key of the resource, as a SecureString (Read-Host -AsSecureString).
    .PARAMETER UseEntraId
        Authenticate with an Entra ID token (needs Az.Accounts and Connect-AzAccount) instead of a key.
    .PARAMETER ResourceGroupName
        Resource group of the Foundry resource (Arm parameter set).
    .PARAMETER AccountName
        Name of the Foundry resource (Microsoft.CognitiveServices account) (Arm parameter set).
    .PARAMETER SubscriptionId
        Subscription of the Foundry resource. Defaults to the subscription of the current Az context.
    .PARAMETER PassThru
        Output the connection (PwshAzureFoundry.Connection). By default the cmdlet outputs nothing.
    .EXAMPLE
        $key = Read-Host -AsSecureString -Prompt 'API key'
        Connect-AzFoundry -Endpoint 'https://lab-foundry.services.ai.azure.com' -ApiKey $key

        Connects with an API key.
    .EXAMPLE
        Connect-AzAccount
        Connect-AzFoundry -Endpoint 'https://lab-foundry.services.ai.azure.com' -UseEntraId

        Connects with an Entra ID token.
    .EXAMPLE
        Connect-AzAccount
        Connect-AzFoundry -ResourceGroupName 'rg-lab' -AccountName 'lab-foundry' -PassThru

        Reads the endpoint and the key of the resource from Azure Resource Manager.
    .NOTES
        Data-plane cmdlets use, in this order: their own -Endpoint/-ApiKey/-UseEntraId parameters, the
        connection set by Connect-AzFoundry, then the AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY
        environment variables. An environment variable holds the key in plain text: use it for CI and
        containers, and prefer Connect-AzFoundry interactively.
    .LINK
        Get-AzFoundryConnection
    .LINK
        Disconnect-AzFoundry
    #>
    [CmdletBinding(DefaultParameterSetName = 'ApiKey', SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType('PwshAzureFoundry.Connection')]
    param(
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'ApiKey')]
        [Parameter(Mandatory, Position = 0, ParameterSetName = 'EntraId')]
        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [Parameter(Mandatory, ParameterSetName = 'ApiKey')]
        [securestring]$ApiKey,

        [Parameter(Mandatory, ParameterSetName = 'EntraId')]
        [Parameter(ParameterSetName = 'Arm')]
        [switch]$UseEntraId,

        [Parameter(Mandatory, ParameterSetName = 'Arm')]
        [ValidatePattern('^[-\w.()]{1,90}$')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory, ParameterSetName = 'Arm')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{1,63}$')]
        [string]$AccountName,

        [Parameter(ParameterSetName = 'Arm')]
        [ValidatePattern('^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$')]
        [string]$SubscriptionId,

        [switch]$PassThru
    )

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Arm') {
            $target = "$AccountName (resource group $ResourceGroupName)"
            if (-not $PSCmdlet.ShouldProcess($target, 'Connect to the Azure AI Foundry resource')) {
                return
            }
            $connection = Get-AzFoundryArmConnection -ResourceGroupName $ResourceGroupName `
                -AccountName $AccountName -SubscriptionId $SubscriptionId -UseEntraId:$UseEntraId
        } else {
            $normalised = ConvertTo-AzFoundryEndpoint -Endpoint $Endpoint
            if (-not $PSCmdlet.ShouldProcess($normalised, 'Connect to the Azure AI Foundry resource')) {
                return
            }
            $connection = [AzFoundryConnection]::new($normalised, $PSCmdlet.ParameterSetName)
            if ($PSCmdlet.ParameterSetName -eq 'ApiKey') {
                $connection.ApiKey = $ApiKey
            }
        }
        $connection.Source = 'Session'

        if ($connection.AuthMode -eq 'EntraId') {
            # Fails now, with a clear message, when Az.Accounts or Connect-AzAccount is missing.
            $null = Get-AzFoundryAccessToken -ResourceUrl ($script:AzFoundryTokenScope -replace '/\.default$', '')
        }
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }

    $script:AzFoundryConnection = $connection
    Write-Verbose "Connected to $connection."

    if ($PassThru) {
        ConvertTo-AzFoundryConnectionInfo -Connection $connection
    }
}
