#Requires -Version 7.4

function Disconnect-AzFoundry {
    <#
    .SYNOPSIS
        Removes the Azure AI Foundry connection of the session.
    .DESCRIPTION
        Clears the connection set by Connect-AzFoundry (endpoint and key) and the Entra ID tokens cached by
        the module. It does not sign out of Azure (Disconnect-AzAccount) and does not change the
        AZURE_FOUNDRY_ENDPOINT / AZURE_FOUNDRY_API_KEY environment variables: when they are set, data-plane
        cmdlets keep using them.

        Running it when not connected does nothing.
    .EXAMPLE
        Disconnect-AzFoundry

        Forgets the endpoint and the key of the session.
    .LINK
        Connect-AzFoundry
    .LINK
        Get-AzFoundryConnection
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([void])]
    param()

    $connection = $script:AzFoundryConnection
    $target = if ($connection) { $connection.Endpoint } else { 'the Azure AI Foundry session' }
    if (-not $PSCmdlet.ShouldProcess($target, 'Disconnect')) {
        return
    }

    if ($connection) {
        Write-Verbose "Disconnected from $connection."
    } else {
        Write-Verbose 'Not connected: nothing to remove.'
    }
    $script:AzFoundryConnection = $null
    $script:AzFoundryTokenCache = @{}

    $envEndpoint = [System.Environment]::GetEnvironmentVariable($script:AzFoundryEndpointEnvVar)
    if (-not [string]::IsNullOrWhiteSpace($envEndpoint)) {
        Write-Verbose "$($script:AzFoundryEndpointEnvVar) is set: data-plane cmdlets will use it."
    }
}
