#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry
<#
.SYNOPSIS
    Triages support tickets with a decision model: urgency, team and priority, sorted by urgency.
.DESCRIPTION
    Uses the current connection (Connect-AzFoundry, or the AZURE_FOUNDRY_* environment variables). Each ticket
    is one /systemone request with three questions: a predicate (urgent), a choice (team) and a score
    (priority). Invoke-AzFoundryDecision outputs one DecisionAnswer per question; this script folds them into
    one row per ticket.

    Ticket text comes from customers: before it goes to a CSV, a leading = + - @ is escaped with a quote so
    that a spreadsheet does not run it as a formula.
.PARAMETER Model
    Decision deployment name.
.PARAMETER Path
    CSV file with Id and Text columns. Without it, the script uses four sample tickets.
.EXAMPLE
    ./samples/decision-triage.ps1 -Model Decision-1.1
.EXAMPLE
    ./samples/decision-triage.ps1 -Path ./tickets.csv | Export-Csv ./triage.csv
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $Model = 'Decision-1.1',

    [ValidateNotNullOrEmpty()]
    [string] $Path
)

$ErrorActionPreference = 'Stop'

$tickets = if ($Path) {
    Import-Csv -LiteralPath $Path
} else {
    @'
Id,Text
101,"Production is down since 8am, our customers cannot pay. Call me now!"
102,"Could you send me the price list for the enterprise plan?"
103,"I was charged twice for my invoice of October."
104,"Small typo on the login page, no rush."
'@ | ConvertFrom-Csv
}

$decision = @{
    Model     = $Model
    Predicate = @{ urgent = 'Does this message convey urgency?' }
    Choice    = @{ team = [ordered]@{ billing = 'Billing'; tech = 'Technical'; sales = 'Sales' } }
    Score     = @{ priority = 'low', 'medium', 'high' }
}

$rows = foreach ($ticket in $tickets) {
    $answers = Invoke-AzFoundryDecision @decision -State $ticket.Text
    $byQuestion = @{}
    foreach ($answer in $answers) { $byQuestion[$answer.Question] = $answer }

    [pscustomobject]@{
        Id       = $ticket.Id
        Urgent   = [math]::Round($byQuestion.urgent.Value, 2)
        Team     = $byQuestion.team.Answer
        Priority = $byQuestion.priority.Answer
        # CSV formula injection: neutralise a leading = + - @ (or tab, CR) in customer text
        Text     = $ticket.Text -replace '^(?=[=+\-@\t\r])', "'"
    }
}
$rows | Sort-Object Urgent -Descending
