#Requires -Version 7.4

function Wait-AzFoundryTask {
    <#
    .SYNOPSIS
        Waits for a .NET task while keeping Ctrl+C responsive, and returns its result.
    .DESCRIPTION
        Polls the task every 200 ms instead of blocking on it, so PowerShell can stop the pipeline (Ctrl+C,
        Select-Object -First) between two polls; the caller's finally block then cancels the request.
        Throws a TimeoutException when the task does not complete within -TimeoutSec. A faulted task
        rethrows its own exception (not an AggregateException).
    .PARAMETER Task
        The task to wait for.
    .PARAMETER TimeoutSec
        Maximum wait, in seconds.
    .PARAMETER Operation
        Text used in the timeout message, for example 'POST https://.../chat/completions'.
    .EXAMPLE
        $response = Wait-AzFoundryTask -Task $client.SendAsync($request) -TimeoutSec 120 -Operation 'POST uri'
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Threading.Tasks.Task]$Task,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [string]$Operation = 'The request'
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    # WaitAny does not throw when the task faults; GetResult() below rethrows the task's own exception.
    while ([System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($Task), 200) -lt 0) {
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSec) {
            throw [System.TimeoutException]::new("$Operation timed out after $TimeoutSec s.")
        }
    }
    try {
        $Task.GetAwaiter().GetResult()
    } catch [System.Management.Automation.MethodInvocationException] {
        throw $_.Exception.InnerException
    }
}
