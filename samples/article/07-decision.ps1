<#
.SYNOPSIS
    Article step 7: ask a decision model typed questions, then triage support tickets.
.DESCRIPTION
    Needs 01-connect.ps1 and 03-select-model.ps1. Decision models do not write text: they return a
    probability (noul), a choice, or a score for each question.
#>
# The urgency example of the Foundry docs
$body = @{
    model     = $decisionModel
    state     = 'The payment integration still fails. Please help today.'
    questions = @{ urgent = @{ type = 'noul'; instructions = 'Does this message convey urgency?' } }
} | ConvertTo-Json -Depth 5

$result = Invoke-RestMethod -Method Post -Uri "$endpoint/providers/microsoft/v1/systemone" `
    -Authentication Bearer -Token $apiKey -ContentType 'application/json' -Body $body
"Probability that the message is urgent: $($result.answers.urgent.noul)"

# Triage a CSV of tickets with the three question types
$tickets = @'
Id,Text
101,"Production is down since 8am, our customers cannot pay. Call me now!"
102,"Could you send me the price list for the enterprise plan?"
103,"I was charged twice for my invoice of October."
104,"Small typo on the login page, no rush."
'@ | ConvertFrom-Csv

$questions = [ordered]@{
    urgent   = @{ type = 'noul'; instructions = 'Does this message convey urgency?' }
    team     = @{ type = 'choice'; criteria = [ordered]@{ billing = 'Billing'; tech = 'Technical'; sales = 'Sales' } }
    priority = @{ type = 'score'; criteria = @('low', 'medium', 'high') }
}

$triage = foreach ($ticket in $tickets) {
    $body = @{ model = $decisionModel; state = $ticket.Text; questions = $questions } | ConvertTo-Json -Depth 5
    $answers = (Invoke-RestMethod -Method Post -Uri "$endpoint/providers/microsoft/v1/systemone" `
            -Authentication Bearer -Token $apiKey -ContentType 'application/json' -Body $body).answers

    # score: probabilities and legend are keyed by level index ("0", "1", "2")
    $level = $answers.priority.probabilities.PSObject.Properties |
        Sort-Object Value -Descending | Select-Object -First 1

    [pscustomobject]@{
        Id       = $ticket.Id
        Urgent   = [math]::Round($answers.urgent.noul, 2)
        Team     = $answers.team.choice
        Priority = $answers.priority.legend.($level.Name)
        Text     = $ticket.Text
    }
}
$triage | Sort-Object Urgent -Descending | Format-Table
