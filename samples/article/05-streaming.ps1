<#
.SYNOPSIS
    Article step 5: stream a chat completion (server-sent events), with HttpClient.
.DESCRIPTION
    Needs 01-connect.ps1 and 03-select-model.ps1. Invoke-RestMethod waits for the whole response, so
    streaming needs System.Net.Http.HttpClient and a loop over the 'data:' lines.
#>
$body = @{
    model      = $chatModel
    stream     = $true
    max_tokens = 200
    messages   = @(@{ role = 'user'; content = 'Write a haiku about PowerShell.' })
} | ConvertTo-Json -Depth 5

$client = [System.Net.Http.HttpClient]::new()
$request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post,
    "$endpoint/openai/v1/chat/completions")
# HttpClient wants the key as a plain string
$request.Headers.Add('api-key', [System.Net.NetworkCredential]::new('', $apiKey).Password)
$request.Content = [System.Net.Http.StringContent]::new($body, [System.Text.Encoding]::UTF8, 'application/json')

# ResponseHeadersRead: return as soon as the headers arrive, without buffering the body
$option   = [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
$response = $client.SendAsync($request, $option).GetAwaiter().GetResult()
$null = $response.EnsureSuccessStatusCode()

$reader = [System.IO.StreamReader]::new($response.Content.ReadAsStream())
while ($null -ne ($line = $reader.ReadLine())) {
    if (-not $line.StartsWith('data: ')) { continue }   # events are separated by blank lines
    $data = $line.Substring(6)
    if ($data -eq '[DONE]') { break }
    $text = ($data | ConvertFrom-Json).choices[0].delta.content
    if ($text) { Write-Host $text -NoNewline }
}
Write-Host

$reader.Dispose(); $response.Dispose(); $request.Dispose(); $client.Dispose()
