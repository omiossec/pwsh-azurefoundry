#Requires -Version 7.4

function New-AzFoundryErrorRecord {
    <#
    .SYNOPSIS
        Builds an ErrorRecord for $PSCmdlet.ThrowTerminatingError() or Write-Error.
    .DESCRIPTION
        Creates the exception (of -ExceptionType, or the given -Exception) and the ErrorRecord, and sets
        ErrorDetails.RecommendedAction when a hint is given. Messages must never contain a secret.
    .PARAMETER Message
        Error message shown to the user.
    .PARAMETER ErrorId
        FullyQualifiedErrorId, for example 'AzFoundryNotConnected'.
    .PARAMETER Category
        ErrorCategory of the record.
    .PARAMETER TargetObject
        Object the error is about (an endpoint, a URI without query, a parameter value).
    .PARAMETER ExceptionType
        Exception type to create. It needs a (string message, Exception inner) constructor.
    .PARAMETER InnerException
        Exception that caused this error.
    .PARAMETER Exception
        A ready-made exception. -ExceptionType and -InnerException are ignored when it is given.
    .PARAMETER RecommendedAction
        What the user can do to fix the error.
    .EXAMPLE
        $record = New-AzFoundryErrorRecord -Message 'Not connected.' -ErrorId 'AzFoundryNotConnected' `
            -Category InvalidOperation -RecommendedAction 'Run Connect-AzFoundry.'
        $PSCmdlet.ThrowTerminatingError($record)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory ErrorRecord; changes no system state.'
    )]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$ErrorId,

        [System.Management.Automation.ErrorCategory]$Category = 'NotSpecified',

        [object]$TargetObject,

        [type]$ExceptionType = [System.Exception],

        [System.Exception]$InnerException,

        [System.Exception]$Exception,

        [string]$RecommendedAction
    )

    if (-not $Exception) {
        $Exception = $ExceptionType::new($Message, $InnerException)
    }

    $record = [System.Management.Automation.ErrorRecord]::new($Exception, $ErrorId, $Category, $TargetObject)
    if ($RecommendedAction) {
        $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Message)
        $record.ErrorDetails.RecommendedAction = $RecommendedAction
    }
    $record
}
