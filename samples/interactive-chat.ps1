#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry
<#
.SYNOPSIS
    A streaming chat REPL in the terminal.
.DESCRIPTION
    Uses the current connection (Connect-AzFoundry, or the AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY
    environment variables). Each answer is printed as it arrives: Invoke-AzFoundryChat -Stream outputs
    ChatChunk objects, and this script writes their Content to the host. -PassThru adds the final ChatResult,
    whose Message goes into the history.

    Type /exit (or an empty line) to quit, /reset to start a new conversation.
.PARAMETER Model
    Chat deployment name.
.PARAMETER SystemPrompt
    System message of the conversation.
.EXAMPLE
    Connect-AzFoundry -ResourceGroupName rg-lab -AccountName <resource>
    ./samples/interactive-chat.ps1 -Model Mistral-Large-3
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'An interactive REPL writes the streamed answer to the terminal.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'final',
    Justification = 'Assigned in the ForEach-Object script block and read after it.')]
[CmdletBinding()]
param(
    [string] $Model = 'Mistral-Large-3',

    [string] $SystemPrompt = 'You are a helpful assistant. Answer briefly.'
)

$ErrorActionPreference = 'Stop'
$history = [System.Collections.Generic.List[object]]::new()

while ($true) {
    $prompt = Read-Host -Prompt 'You'
    if (-not $prompt -or $prompt -eq '/exit') { break }
    if ($prompt -eq '/reset') {
        $history.Clear()
        Write-Host 'New conversation.' -ForegroundColor DarkGray
        continue
    }

    $history.Add((New-AzFoundryMessage -Role user -Content $prompt))
    Write-Host 'AI : ' -NoNewline -ForegroundColor Cyan
    $final = $null
    Invoke-AzFoundryChat -Model $Model -Message $history -SystemPrompt $SystemPrompt -Stream -PassThru |
        ForEach-Object {
            if ($_.PSObject.TypeNames -contains 'PwshAzureFoundry.ChatResult') {
                $final = $_
            } elseif ($_.Content) {
                Write-Host $_.Content -NoNewline
            }
        }
    Write-Host
    if ($final) {
        $history.Add($final.Message)
        Write-Host ("[{0} tokens]" -f $final.Usage.TotalTokens) -ForegroundColor DarkGray
    }
}
