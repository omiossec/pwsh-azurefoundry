#Requires -Version 7.4

function Wait-AzFoundryDeploymentReady {
    <#
    .SYNOPSIS
        Waits until a new deployment answers on the data plane.
    .DESCRIPTION
        Right after ARM reports Succeeded, the data plane still answers 404 DeploymentNotFound for about 20 s, or
        400 DeploymentCreating while a partner model is provisioning (spec section 2.1). This helper sends a
        minimal real request every $script:AzFoundryReadinessIntervalSec seconds until it succeeds:

          decision        POST /providers/microsoft/v1/systemone, one predicate on the state 'ping'
          chatCompletion  POST /openai/v1/chat/completions, 'ping' with max_tokens 1
          embeddings      POST /openai/v1/embeddings, input 'ping'

        Each probe uses a few tokens. Models with none of these capabilities (image, audio...) are not probed.

        The data-plane connection is the session connection when it points to the same resource. Otherwise it is
        built from ARM with the auth mode of the session: an Entra ID session probes with Entra ID and never calls
        listKeys. A key session, or no session, uses the key from listKeys, and Entra ID when key authentication
        is disabled on the resource.

        Never throws: a timeout or another error is a warning, because the deployment itself succeeded.
        Returns $true when the deployment answered, $false otherwise.
    .PARAMETER Target
        The resource (Resolve-AzFoundryArmTarget).
    .PARAMETER Name
        Deployment name.
    .PARAMETER Task
        Capabilities of the model (chatCompletion, embeddings, decision...).
    .PARAMETER TimeoutSec
        Maximum wait. Defaults to $script:AzFoundryReadinessTimeoutSec.
    .EXAMPLE
        Wait-AzFoundryDeploymentReady -Target $target -Name 'embed' -Task 'embeddings'
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object]$Target,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowEmptyCollection()]
        [string[]]$Task = @(),

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryReadinessTimeoutSec
    )

    $probe = if ($Task -contains 'decision') {
        @{
            Path = '/providers/microsoft/v1/systemone'
            Body = [ordered]@{
                model     = $Name
                state     = 'ping'
                questions = @{ ready = @{ type = 'noul'; instructions = 'Is this a test message?' } }
            }
        }
    } elseif ($Task -contains 'chatCompletion') {
        @{
            Path = '/openai/v1/chat/completions'
            Body = [ordered]@{ model = $Name; messages = @(@{ role = 'user'; content = 'ping' }); max_tokens = 1 }
        }
    } elseif ($Task -contains 'embeddings') {
        @{ Path = '/openai/v1/embeddings'; Body = [ordered]@{ model = $Name; input = 'ping' } }
    }
    if (-not $probe) {
        Write-Verbose "No readiness check for $Name (no chat, embeddings or decision capability)."
        return $true
    }

    try {
        $session = $script:AzFoundryConnection
        $connection = if ($session -and $session.AccountName -and
            [string]::Equals($session.AccountName, $Target.AccountName, [StringComparison]::OrdinalIgnoreCase)) {
            $session
        } elseif ($session -and $session.AuthMode -eq 'EntraId') {
            Get-AzFoundryArmConnection -ResourceGroupName $Target.ResourceGroupName `
                -AccountName $Target.AccountName -SubscriptionId $Target.SubscriptionId -UseEntraId
        } else {
            try {
                Get-AzFoundryArmConnection -ResourceGroupName $Target.ResourceGroupName `
                    -AccountName $Target.AccountName -SubscriptionId $Target.SubscriptionId
            } catch {
                if ($_.FullyQualifiedErrorId -notlike 'AzFoundryLocalAuthDisabled*') {
                    throw
                }
                Get-AzFoundryArmConnection -ResourceGroupName $Target.ResourceGroupName `
                    -AccountName $Target.AccountName -SubscriptionId $Target.SubscriptionId -UseEntraId
            }
        }
    } catch {
        Write-Warning "Could not check that $Name answers on the data plane: $($_.Exception.Message)"
        return $false
    }

    Write-Verbose "Checking that $Name answers on $($connection.Endpoint)$($probe.Path)."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $null = Invoke-AzFoundryRequest -Connection $connection -Path $probe.Path -Body $probe.Body -TimeoutSec 60
            Write-Verbose ('{0} answers on the data plane ({1:N0} s).' -f $Name, $stopwatch.Elapsed.TotalSeconds)
            return $true
        } catch {
            if ($_.CategoryInfo.Category -notin 'ObjectNotFound', 'ResourceBusy') {
                Write-Warning "The readiness check of $Name failed: $($_.Exception.Message)"
                return $false
            }
        }
        if ($stopwatch.Elapsed.TotalSeconds + $script:AzFoundryReadinessIntervalSec -gt $TimeoutSec) {
            Write-Warning ("$Name does not answer on the data plane yet after $TimeoutSec s. " +
                'It can take a few minutes; retry later.')
            return $false
        }
        Write-Verbose ('{0} is not reachable yet ({1:N0} s); waiting.' -f $Name, $stopwatch.Elapsed.TotalSeconds)
        Start-Sleep -Seconds $script:AzFoundryReadinessIntervalSec
    }
}
