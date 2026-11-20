#Requires -Version 7.4

function ConvertTo-AzFoundryEmbedding {
    <#
    .SYNOPSIS
        Converts an /openai/v1/embeddings response into PwshAzureFoundry.Embedding objects.
    .DESCRIPTION
        Outputs one object per input text, in the input order: Index (position in the whole input, starting at
        -StartIndex), Text, Vector ([float[]]), Dimensions and Model. The response items are matched to the
        texts by their index field; a response that does not hold exactly one vector per text is an error.
    .PARAMETER Response
        Parsed embeddings response ({ data[{ index, embedding }], model, usage }).
    .PARAMETER Text
        The texts sent in this request, in order.
    .PARAMETER StartIndex
        Index of the first text of this request in the whole input (batching).
    .EXAMPLE
        ConvertTo-AzFoundryEmbedding -Response $response -Text $batch -StartIndex 16
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Embedding')]
    param(
        [Parameter(Mandatory)]
        [object]$Response,

        [Parameter(Mandatory)]
        [string[]]$Text,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$StartIndex = 0
    )

    $vectors = [object[]]::new($Text.Count)
    foreach ($item in @($Response.data)) {
        $index = [int]$item.index
        if ($index -lt 0 -or $index -ge $Text.Count -or $null -ne $vectors[$index]) {
            throw [System.InvalidOperationException]::new(
                "The embeddings response has an unexpected item index ($index) for $($Text.Count) input(s).")
        }
        $vectors[$index] = [float[]]@($item.embedding)
    }
    for ($i = 0; $i -lt $Text.Count; $i++) {
        if ($null -eq $vectors[$i]) {
            throw [System.InvalidOperationException]::new(
                "The embeddings response has no vector for input $i of $($Text.Count).")
        }
    }

    for ($i = 0; $i -lt $Text.Count; $i++) {
        [pscustomobject]@{
            PSTypeName = 'PwshAzureFoundry.Embedding'
            Index      = $StartIndex + $i
            Text       = $Text[$i]
            Vector     = $vectors[$i]
            Dimensions = $vectors[$i].Length
            Model      = $Response.model
        }
    }
}
