<#
.SYNOPSIS
    Article step 4: one chat completion request, with plain REST.
.DESCRIPTION
    Needs 01-connect.ps1 and 03-select-model.ps1. The key goes in 'Authorization: Bearer', so it can stay a
    SecureString (the 'api-key' header works too, but needs the key in plain text).
#>
$body = @{
    model      = $chatModel
    max_tokens = 200
    messages   = @(
        @{ role = 'user'; content = 'In one sentence, what is Azure AI Foundry?' }
    )
} | ConvertTo-Json -Depth 5   # the default depth (2) silently truncates nested objects

$response = Invoke-RestMethod -Method Post -Uri "$endpoint/openai/v1/chat/completions" `
    -Authentication Bearer -Token $apiKey -ContentType 'application/json' -Body $body

$response.choices[0].message.content
$response.usage
