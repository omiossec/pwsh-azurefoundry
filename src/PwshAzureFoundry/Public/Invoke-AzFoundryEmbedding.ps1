#Requires -Version 7.4

function Invoke-AzFoundryEmbedding {
    <#
    .SYNOPSIS
        Computes embeddings with a model deployed on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls POST /openai/v1/embeddings on the resource. The deployment is picked by -Model.

        Texts come from -InputText or the pipeline and are sent in batches of -BatchSize texts (default 16), one
        request per batch. A batch is sent as soon as it is full, so results flow while the input is read.

        Output: one PwshAzureFoundry.Embedding per text, in the input order: Index (0-based position in the whole
        input), Text, Vector ([float[]]), Dimensions and Model. With -Raw, the parsed response of each request
        (with usage) instead.
    .PARAMETER Model
        Embedding deployment name, for example text-embedding-3-small.
    .PARAMETER InputText
        Texts to embed. Accepts pipeline input.
    .PARAMETER Dimensions
        Length of the vectors (dimensions), for models that support it, such as text-embedding-3-*.
    .PARAMETER EncodingFormat
        Vector encoding (encoding_format). Only 'float' is supported.
    .PARAMETER BatchSize
        Number of texts per request (default 16). The deployment limit is in its capabilities
        (embeddingsMaxInputs, 2048 for text-embedding-3-small).
    .PARAMETER Raw
        Output the response of each request as parsed JSON instead of Embedding objects.
    .PARAMETER TimeoutSec
        Request timeout in seconds (default 120).
    .PARAMETER Endpoint
        Endpoint of the resource, overriding the session connection (needs -ApiKey or -UseEntraId, unless it is
        the resource of the session).
    .PARAMETER ApiKey
        API key (SecureString) overriding the session authentication.
    .PARAMETER UseEntraId
        Use an Entra ID token (Az.Accounts and Connect-AzAccount) instead of a key.
    .PARAMETER AllowCustomEndpoint
        Accept an -Endpoint host outside Azure (*.services.ai.azure.com, *.openai.azure.com,
        *.cognitiveservices.azure.com), such as a custom domain or a gateway. The key or token is sent to it;
        a warning is shown once per host.
    .EXAMPLE
        Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small' -InputText 'Hello', 'Bonjour'

        Returns two embeddings.
    .EXAMPLE
        Get-Content ./faq.txt | Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small' -Dimensions 256 -BatchSize 64

        Embeds every line of a file, 64 lines per request, as 256-dimension vectors.
    .NOTES
        The connection comes from, in this order: -Endpoint/-ApiKey/-UseEntraId, the connection set by
        Connect-AzFoundry, then the AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY environment variables.
    .LINK
        Invoke-AzFoundryChat
    .LINK
        Connect-AzFoundry
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.Embedding')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateNotNullOrEmpty()]
        [string[]]$InputText,

        [ValidateRange(1, 65536)]
        [int]$Dimensions,

        [ValidateSet('float')]
        [string]$EncodingFormat,

        [ValidateRange(1, 2048)]
        [int]$BatchSize = 16,

        [switch]$Raw,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [securestring]$ApiKey,

        [switch]$UseEntraId,

        [switch]$AllowCustomEndpoint
    )

    begin {
        $connectionParameters = @{}
        foreach ($name in 'Endpoint', 'ApiKey', 'UseEntraId', 'AllowCustomEndpoint') {
            if ($PSBoundParameters.ContainsKey($name)) {
                $connectionParameters[$name] = $PSBoundParameters[$name]
            }
        }
        try {
            $connection = Resolve-AzFoundryConnection @connectionParameters
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $options = [ordered]@{}
        if ($PSBoundParameters.ContainsKey('Dimensions')) {
            $options['dimensions'] = $Dimensions
        }
        if ($PSBoundParameters.ContainsKey('EncodingFormat')) {
            $options['encoding_format'] = $EncodingFormat
        }

        $pending = [System.Collections.Generic.List[string]]::new()
        $sent = 0

        $sendBatch = {
            $texts = $pending.ToArray()
            $pending.Clear()
            $body = [ordered]@{
                model = $Model
                input = $texts
            }
            foreach ($key in $options.Keys) {
                $body[$key] = $options[$key]
            }
            Write-Verbose ('Embeddings with {0}: texts {1} to {2}.' -f $Model, $sent, ($sent + $texts.Count - 1))
            $response = Invoke-AzFoundryRequest -Connection $connection -Path '/openai/v1/embeddings' -Body $body `
                -TimeoutSec $TimeoutSec
            if ($response.usage) {
                Write-Verbose ('Tokens: {0}.' -f $response.usage.total_tokens)
            }
            # Dot-sourced by process and end, so this updates the counter of the cmdlet.
            $start = $sent
            $sent += $texts.Count
            if ($Raw) {
                return $response
            }
            ConvertTo-AzFoundryEmbedding -Response $response -Text $texts -StartIndex $start
        }
    }

    process {
        foreach ($text in $InputText) {
            $pending.Add($text)
            if ($pending.Count -ge $BatchSize) {
                try {
                    . $sendBatch
                } catch {
                    $PSCmdlet.ThrowTerminatingError($_)
                }
            }
        }
    }

    end {
        if ($pending.Count -gt 0) {
            try {
                . $sendBatch
            } catch {
                $PSCmdlet.ThrowTerminatingError($_)
            }
        }
    }
}
