#Requires -Version 7.4

function ConvertTo-AzFoundryDecisionQuestion {
    <#
    .SYNOPSIS
        Builds the questions object of a /systemone request from the question parameters.
    .DESCRIPTION
        Returns an ordered dictionary id -> definition, in this order: predicates ({ type = 'noul';
        instructions }), choices ({ type = 'choice'; criteria = option key -> label }), scores ({ type = 'score';
        criteria = levels }), then raw questions as-is.

        Errors (terminating, InvalidArgument): an empty id or a duplicate id (AzFoundryInvalidDecisionQuestion),
        empty instructions, a choice with fewer than two options, a score with fewer than two levels, a raw
        question without a type, and no question at all (AzFoundryDecisionNoQuestion).
    .PARAMETER Predicate
        id -> instructions.
    .PARAMETER Choice
        id -> dictionary of option key -> label.
    .PARAMETER Score
        id -> list of levels, lowest first.
    .PARAMETER Question
        id -> raw definition with a type.
    .EXAMPLE
        ConvertTo-AzFoundryDecisionQuestion -Predicate @{ urgent = 'Does this message convey urgency?' }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [System.Collections.IDictionary]$Predicate,
        [System.Collections.IDictionary]$Choice,
        [System.Collections.IDictionary]$Score,
        [System.Collections.IDictionary]$Question
    )

    $questions = [ordered]@{}

    $fail = {
        param([string]$Message, [string]$ErrorId = 'AzFoundryInvalidDecisionQuestion')
        $PSCmdlet.ThrowTerminatingError((New-AzFoundryErrorRecord -Message $Message -ErrorId $ErrorId `
                    -Category InvalidArgument -ExceptionType ([System.ArgumentException])))
    }
    $add = {
        param([object]$Id, [System.Collections.IDictionary]$Definition)
        $key = [string]$Id
        if ([string]::IsNullOrWhiteSpace($key)) {
            & $fail 'Question ids must not be empty.'
        }
        if ($questions.Contains($key)) {
            & $fail "Question id '$key' is used more than once."
        }
        $questions[$key] = $Definition
    }

    foreach ($id in $(if ($Predicate) { @($Predicate.Keys) })) {
        $instructions = [string]$Predicate[$id]
        if ([string]::IsNullOrWhiteSpace($instructions)) {
            & $fail "Predicate '$id' needs non-empty instructions."
        }
        & $add $id ([ordered]@{ type = 'noul'; instructions = $instructions })
    }

    foreach ($id in $(if ($Choice) { @($Choice.Keys) })) {
        $options = $Choice[$id]
        if ($options -isnot [System.Collections.IDictionary] -or $options.Count -lt 2) {
            & $fail "Choice '$id' must be a dictionary of at least two option key -> label pairs."
        }
        & $add $id ([ordered]@{ type = 'choice'; criteria = $options })
    }

    foreach ($id in $(if ($Score) { @($Score.Keys) })) {
        $levels = @($Score[$id] | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($levels.Count -lt 2) {
            & $fail "Score '$id' must list at least two levels."
        }
        & $add $id ([ordered]@{ type = 'score'; criteria = $levels })
    }

    foreach ($id in $(if ($Question) { @($Question.Keys) })) {
        $definition = $Question[$id]
        if ($definition -isnot [System.Collections.IDictionary] -or -not $definition['type']) {
            & $fail "Question '$id' must be a dictionary with a 'type' entry."
        }
        & $add $id $definition
    }

    if ($questions.Count -eq 0) {
        & $fail 'Specify at least one -Predicate, -Choice, -Score or -Question.' 'AzFoundryDecisionNoQuestion'
    }

    Write-Output -InputObject $questions -NoEnumerate
}
