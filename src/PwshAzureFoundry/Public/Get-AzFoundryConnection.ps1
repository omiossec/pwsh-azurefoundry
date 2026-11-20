#Requires -Version 7.4

function Get-AzFoundryConnection {
    <#
    .SYNOPSIS
        Shows the Azure AI Foundry connection of the session.
    .DESCRIPTION
        Outputs the connection that data-plane cmdlets use when they get no -Endpoint: the one set by
        Connect-AzFoundry (Source = Session) or, when there is none, the one read from the
        AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY environment variables (Source = Environment).
        Outputs nothing when neither is set.

        The output (PwshAzureFoundry.Connection) never contains the key.
    .EXAMPLE
        Get-AzFoundryConnection

        Shows the account, endpoint, authentication mode and source of the connection.
    .EXAMPLE
        Get-AzFoundryConnection | Format-List

        Also shows the resource group and the subscription (known after Connect-AzFoundry -ResourceGroupName).
    .NOTES
        An environment variable holds the key in plain text: use it for CI and containers, and prefer
        Connect-AzFoundry interactively.
    .LINK
        Connect-AzFoundry
    .LINK
        Disconnect-AzFoundry
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Connection')]
    param()

    if ($script:AzFoundryConnection) {
        ConvertTo-AzFoundryConnectionInfo -Connection $script:AzFoundryConnection
        return
    }

    if ([string]::IsNullOrWhiteSpace([System.Environment]::GetEnvironmentVariable($script:AzFoundryEndpointEnvVar))) {
        Write-Verbose ('Not connected: run Connect-AzFoundry, or set the {0} and {1} environment variables.' -f
            $script:AzFoundryEndpointEnvVar, $script:AzFoundryApiKeyEnvVar)
        return
    }

    try {
        $connection = Resolve-AzFoundryConnection
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
    ConvertTo-AzFoundryConnectionInfo -Connection $connection
}
