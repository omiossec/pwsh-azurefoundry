#Requires -Version 7.4
#Requires -Modules PwshAzureFoundry
<#
.SYNOPSIS
    Semantic search over a few sentences with embeddings and cosine similarity.
.DESCRIPTION
    Uses the current connection (Connect-AzFoundry, or the AZURE_FOUNDRY_* environment variables). Embeds the
    documents in one batch, embeds the query, and ranks the documents by cosine similarity.
.PARAMETER Model
    Embedding deployment name (for example text-embedding-3-small).
.PARAMETER Query
    The text to search for.
.EXAMPLE
    ./samples/embedding-search.ps1 -Model text-embedding-3-small -Query 'How do I restart a service?'
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $Model = 'text-embedding-3-small',

    [ValidateNotNullOrEmpty()]
    [string] $Query = 'How do I restart a Windows service?'
)

$ErrorActionPreference = 'Stop'

function Get-CosineSimilarity {
    param([float[]] $A, [float[]] $B)
    $dot = 0.0; $normA = 0.0; $normB = 0.0
    for ($i = 0; $i -lt $A.Length; $i++) {
        $dot += $A[$i] * $B[$i]
        $normA += $A[$i] * $A[$i]
        $normB += $B[$i] * $B[$i]
    }
    $dot / ([math]::Sqrt($normA) * [math]::Sqrt($normB))
}

$documents = @(
    'Restart-Service -Name Spooler restarts the print spooler.'
    'Get-Process lists the processes running on the computer.'
    'New-AzResourceGroup creates a resource group in Azure.'
    'Stop-Service and Start-Service stop and start a Windows service.'
    'ConvertTo-Json turns an object into a JSON string.'
)

$vectors = $documents | Invoke-AzFoundryEmbedding -Model $Model
$queryVector = (Invoke-AzFoundryEmbedding -Model $Model -InputText $Query).Vector

$vectors |
    Select-Object @{ Name = 'Score'; Expression = { [math]::Round((Get-CosineSimilarity $_.Vector $queryVector), 3) } },
    Text |
    Sort-Object Score -Descending
