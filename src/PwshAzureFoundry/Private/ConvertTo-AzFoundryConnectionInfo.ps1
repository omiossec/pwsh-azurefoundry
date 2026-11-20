#Requires -Version 7.4

function ConvertTo-AzFoundryConnectionInfo {
    <#
    .SYNOPSIS
        Turns a connection into the object shown to the user.
    .DESCRIPTION
        Outputs a PwshAzureFoundry.Connection object with the endpoint, authentication mode, resource ids and
        source. It has no key property at all (spec section 5.1: the key is never shown).
    .PARAMETER Connection
        The connection to show.
    .EXAMPLE
        ConvertTo-AzFoundryConnectionInfo -Connection $script:AzFoundryConnection
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Connection')]
    param(
        [Parameter(Mandatory)]
        [AzFoundryConnection]$Connection
    )

    [pscustomobject]@{
        PSTypeName        = 'PwshAzureFoundry.Connection'
        Endpoint          = $Connection.Endpoint
        AuthMode          = $Connection.AuthMode
        AccountName       = $Connection.AccountName
        ResourceGroupName = $Connection.ResourceGroupName
        SubscriptionId    = $Connection.SubscriptionId
        Source            = $Connection.Source
    }
}
