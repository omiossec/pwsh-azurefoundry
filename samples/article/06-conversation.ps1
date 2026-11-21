<#
.SYNOPSIS
    Article step 6: a multi-turn chat. The model keeps no state: send the whole history every time.
.DESCRIPTION
    Needs 01-connect.ps1 and 03-select-model.ps1. Reproduces the Paris example of the Foundry docs.
#>
$history = [System.Collections.Generic.List[hashtable]]::new()
$history.Add(@{ role = 'system'; content = 'You are a concise travel guide.' })

foreach ($question in 'I am going to Paris, what should I see?', 'What is so great about #1?') {
    $history.Add(@{ role = 'user'; content = $question })

    $body = @{
        model       = $chatModel
        messages    = $history
        max_tokens  = 400
        temperature = 0.8      # the accepted range depends on the model (Mistral: 0 to 1)
        top_p       = 0.1
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Method Post -Uri "$endpoint/openai/v1/chat/completions" `
        -Authentication Bearer -Token $apiKey -ContentType 'application/json' -Body $body

    $answer = $response.choices[0].message
    $history.Add(@{ role = $answer.role; content = $answer.content })
    "> $question`n$($answer.content)`n"
}
