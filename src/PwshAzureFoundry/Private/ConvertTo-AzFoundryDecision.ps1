#Requires -Version 7.4

function ConvertTo-AzFoundryDecision {
    <#
    .SYNOPSIS
        Converts a /systemone response into PwshAzureFoundry.DecisionAnswer objects, one per question.
    .DESCRIPTION
        Maps each entry of response.answers (spec section 5.2):
          - noul:   Answer = noul >= Threshold, Value = noul, Confidence = probability of the answer given.
          - choice: Answer = chosen key, Confidence, Probabilities (option key -> p).
          - score:  Answer = label of the most probable level, Value = expected level index (0-based),
                    Confidence, Probabilities (level label -> p, legend applied).
        Other types are output with Answer, Value and Probabilities left empty, and a warning.

        Answers come out in the order of -Questions (the request order); answers the request did not ask for
        come after them, in the response order.
    .PARAMETER Response
        Parsed /systemone response ({ model, answers, usage }).
    .PARAMETER Questions
        The questions sent, as id -> definition. Gives the output order and the option order of choices.
    .PARAMETER Threshold
        Cut-off for the Answer of a noul (predicate) question. Defaults to 0.5.
    .PARAMETER Headers
        Response headers, for the RateLimit property.
    .PARAMETER State
        The state sent, copied to each answer so piped states can be told apart.
    .EXAMPLE
        ConvertTo-AzFoundryDecision -Response $response.Content -Questions $questions -Headers $response.Headers
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.DecisionAnswer')]
    param(
        [Parameter(Mandatory)]
        [object]$Response,

        [System.Collections.IDictionary]$Questions,

        [ValidateRange(0.0, 1.0)]
        [double]$Threshold = 0.5,

        [System.Collections.IDictionary]$Headers,

        [AllowNull()]
        [object]$State
    )

    $answers = $Response.answers
    if ($null -eq $answers) {
        return
    }
    $answerIds = @($answers.PSObject.Properties.Name)
    $ordered = [System.Collections.Generic.List[string]]::new()
    if ($Questions) {
        foreach ($id in $Questions.Keys) {
            if ($id -in $answerIds) {
                $ordered.Add([string]$id)
            }
        }
    }
    foreach ($id in $answerIds) {
        if (-not $ordered.Contains($id)) {
            $ordered.Add($id)
        }
    }

    $rateLimit = ConvertTo-AzFoundryRateLimit -Headers $Headers
    $usage = $Response.PSObject.Properties['usage']
    $inputTokens = if ($usage -and $usage.Value) { $usage.Value.input_tokens }
    $outputTokens = if ($usage -and $usage.Value) { $usage.Value.output_tokens }

    foreach ($id in $ordered) {
        $item = $answers.$id
        $type = [string]$item.type
        $answer = $null
        $value = $null
        $confidence = $null
        $probabilities = $null

        switch ($type) {
            'noul' {
                $value = [double]$item.noul
                $answer = $value -ge $Threshold
                $confidence = if ($answer) { $value } else { 1.0 - $value }
            }
            'choice' {
                $answer = [string]$item.choice
                $confidence = if ($null -ne $item.confidence) { [double]$item.confidence }
                $probabilities = [ordered]@{}
                $given = $item.probabilities
                if ($given) {
                    $optionOrder = @()
                    $definition = if ($Questions -and $Questions.Contains($id)) { $Questions[$id] }
                    if ($definition -is [System.Collections.IDictionary] -and
                        $definition['criteria'] -is [System.Collections.IDictionary]) {
                        $optionOrder = @($definition['criteria'].Keys | ForEach-Object { [string]$_ })
                    }
                    $names = @($given.PSObject.Properties.Name)
                    foreach ($name in @($optionOrder | Where-Object { $_ -in $names }) +
                        @($names | Where-Object { $_ -notin $optionOrder })) {
                        $probabilities[$name] = [double]$given.$name
                    }
                }
            }
            'score' {
                $value = [double]$item.score
                $confidence = if ($null -ne $item.confidence) { [double]$item.confidence }
                $legend = $item.PSObject.Properties['legend']
                $given = $item.probabilities
                $probabilities = [ordered]@{}
                $best = $null
                $bestP = -1.0
                if ($given) {
                    $levels = @($given.PSObject.Properties.Name | Sort-Object { [int]$_ })
                    foreach ($level in $levels) {
                        $label = if ($legend -and $legend.Value -and $null -ne $legend.Value.$level) {
                            [string]$legend.Value.$level
                        } else {
                            [string]$level
                        }
                        $p = [double]$given.$level
                        $probabilities[$label] = $p
                        if ($p -gt $bestP) {
                            $bestP = $p
                            $best = $label
                        }
                    }
                }
                $answer = $best
            }
            default {
                Write-Warning "Answer '$id' has the unknown type '$type'; use -Raw to see it."
            }
        }

        [pscustomobject]@{
            PSTypeName    = 'PwshAzureFoundry.DecisionAnswer'
            Question      = $id
            Type          = $type
            Answer        = $answer
            Value         = $value
            Confidence    = $confidence
            Probabilities = $probabilities
            Model         = $Response.model
            InputTokens   = $inputTokens
            OutputTokens  = $outputTokens
            RateLimit     = $rateLimit
            State         = $State
        }
    }
}
