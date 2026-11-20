#Requires -Version 7.4

function Import-AzFoundryAzAccounts {
    <#
    .SYNOPSIS
        Loads Az.Accounts on demand, with a clear error when it is missing or too old.
    .DESCRIPTION
        Az.Accounts is a soft dependency: only the management cmdlets and Entra ID authentication need it,
        and key-based inference works without it. This helper returns at once when a recent enough version
        is already loaded, otherwise imports the newest installed version into the global scope (so the
        session and the module share one copy).
    .EXAMPLE
        Import-AzFoundryAzAccounts
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseSingularNouns', '',
        Justification = 'Named after the Az.Accounts module it imports.'
    )]
    [CmdletBinding()]
    [OutputType([void])]
    param()

    $minimumVersion = [version]$script:AzFoundryAzAccountsMinVersion
    $install = "Install-PSResource -Name Az.Accounts -MinimumVersion $minimumVersion"

    $loaded = Get-Module -Name 'Az.Accounts' | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($loaded) {
        if ($loaded.Version -lt $minimumVersion) {
            $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                        -Message "Az.Accounts $($loaded.Version) is loaded, but $minimumVersion or later is required." `
                        -ErrorId 'AzFoundryAzAccountsTooOld' -Category NotInstalled -TargetObject 'Az.Accounts' `
                        -ExceptionType ([System.InvalidOperationException]) `
                        -RecommendedAction "Update it ($install), then start a new PowerShell session."))
        }
        return
    }

    $available = Get-Module -Name 'Az.Accounts' -ListAvailable |
        Where-Object { $_.Version -ge $minimumVersion } |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
    if (-not $available) {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message ("This command needs the Az.Accounts module ($minimumVersion or later), which is not " +
                    'installed. Inference with an API key works without it.') `
                    -ErrorId 'AzFoundryAzAccountsNotInstalled' -Category NotInstalled -TargetObject 'Az.Accounts' `
                    -ExceptionType ([System.InvalidOperationException]) `
                    -RecommendedAction "Install it with: $install, then run Connect-AzAccount."))
    }

    Write-Verbose "Importing Az.Accounts $($available.Version)."
    try {
        Import-Module -Name $available.Path -Global -ErrorAction Stop -Verbose:$false
    } catch {
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord `
                    -Message "Az.Accounts $($available.Version) could not be imported: $($_.Exception.Message)" `
                    -ErrorId 'AzFoundryAzAccountsImportFailed' -Category ResourceUnavailable `
                    -TargetObject 'Az.Accounts' `
                    -InnerException $_.Exception `
                    -RecommendedAction 'Start a new PowerShell session (another Az.Accounts version may be loaded).'))
    }
}
