#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:savedEndpoint = $env:AZURE_FOUNDRY_ENDPOINT
    $script:savedKey = $env:AZURE_FOUNDRY_API_KEY
    $env:AZURE_FOUNDRY_ENDPOINT = $null
    $env:AZURE_FOUNDRY_API_KEY = $null

    $script:fixture = Get-TestFixture 'embedding.json' | ConvertFrom-Json
}

AfterAll {
    $env:AZURE_FOUNDRY_ENDPOINT = $script:savedEndpoint
    $env:AZURE_FOUNDRY_API_KEY = $script:savedKey
    Remove-Variable -Name AzFoundryTestRequests -Scope Global -ErrorAction Ignore
    InModuleScope PwshAzureFoundry { $script:AzFoundryConnection = $null }
}

Describe 'Invoke-AzFoundryEmbedding' {
    BeforeEach {
        $global:AzFoundryTestRequests = [System.Collections.Generic.List[object]]::new()
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString 'emb-key-0123')

        # Answers with one short vector per input, in reverse order (the cmdlet must sort by index).
        Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry {
            $global:AzFoundryTestRequests.Add([pscustomobject]@{ Path = $Path; Body = $Body; TimeoutSec = $TimeoutSec })
            $inputs = @($Body.input)
            $data = for ($i = $inputs.Count - 1; $i -ge 0; $i--) {
                [pscustomobject]@{ object = 'embedding'; index = $i; embedding = @([double]$inputs[$i].Length, 0.5) }
            }
            [pscustomobject]@{
                object = 'list'; data = @($data); model = 'text-embedding-3-small'
                usage  = [pscustomobject]@{ prompt_tokens = $inputs.Count; total_tokens = $inputs.Count }
            }
        }
    }

    Context 'request body' {
        It 'sends model and input only when no option is bound' {
            $null = Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small' -InputText 'Hello'
            $request = $global:AzFoundryTestRequests[-1]
            $request.Path | Should -Be '/openai/v1/embeddings'
            ConvertTo-TestCanonicalJson $request.Body | Should -Be '{"input":["Hello"],"model":"text-embedding-3-small"}'
        }

        It 'maps -Dimensions and -EncodingFormat' {
            $null = Invoke-AzFoundryEmbedding -Model 'm' -InputText 'a' -Dimensions 256 -EncodingFormat float -TimeoutSec 9
            $request = $global:AzFoundryTestRequests[-1]
            $request.Body.dimensions | Should -Be 256
            $request.Body.encoding_format | Should -Be 'float'
            $request.TimeoutSec | Should -Be 9
        }

        It 'rejects an empty text before any request' {
            { Invoke-AzFoundryEmbedding -Model 'm' -InputText 'a', '' } | Should -Throw
            Should -Invoke Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }
    }

    Context 'batching' {
        It 'splits <Count> texts in batches of <Size>: <Expected>' -ForEach @(
            @{ Count = 5; Size = 2; Expected = @(2, 2, 1) }
            @{ Count = 4; Size = 2; Expected = @(2, 2) }
            @{ Count = 3; Size = 16; Expected = @(3) }
            @{ Count = 1; Size = 1; Expected = @(1) }
        ) {
            $texts = 1..$Count | ForEach-Object { 'x' * $_ }
            $result = @($texts | Invoke-AzFoundryEmbedding -Model 'm' -BatchSize $Size)

            @($global:AzFoundryTestRequests | ForEach-Object { @($_.Body.input).Count }) | Should -Be $Expected
            $result.Index | Should -Be @(0..($Count - 1))
            $result.Text | Should -Be $texts
            # The mock encodes the text length in the first component: vectors match their text.
            $result | ForEach-Object { $_.Vector[0] | Should -Be $_.Text.Length }
        }

        It 'batches an -InputText array the same way as pipeline input' {
            $result = @(Invoke-AzFoundryEmbedding -Model 'm' -InputText 'a', 'bb', 'ccc' -BatchSize 2)
            $global:AzFoundryTestRequests.Count | Should -Be 2
            $result.Index | Should -Be @(0, 1, 2)
        }

        It 'returns one response per request with -Raw' {
            $raw = @('a', 'b', 'c' | Invoke-AzFoundryEmbedding -Model 'm' -BatchSize 2 -Raw)
            $raw.Count | Should -Be 2
            $raw[0].usage.total_tokens | Should -Be 2
            $raw[0].PSObject.TypeNames[0] | Should -Not -Be 'PwshAzureFoundry.Embedding'
        }
    }

    Context 'output' {
        It 'maps the fixture response' {
            Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry { $fixture }
            $result = @(Invoke-AzFoundryEmbedding -Model 'text-embedding-3-small' -InputText 'one', 'two')

            $result.Count | Should -Be 2
            $result[0].PSObject.TypeNames[0] | Should -Be 'PwshAzureFoundry.Embedding'
            $result[0].Vector | Should -BeOfType [float]
            $result[0].Vector.GetType() | Should -Be ([float[]])
            $result.Dimensions | Should -Be @(1536, 1536)
            $result[0].Model | Should -Be 'text-embedding-3-small'
            $result[1].Vector[0] | Should -Be ([float]$fixture.data[1].embedding[0])
        }

        It 'fails when the response does not hold one vector per input' {
            Mock Invoke-AzFoundryRequest -ModuleName PwshAzureFoundry { $fixture }
            { Invoke-AzFoundryEmbedding -Model 'm' -InputText 'one', 'two', 'three' } |
                Should -Throw '*no vector for input 2 of 3*'
        }
    }
}

Describe 'Invoke-AzFoundryEmbedding over HTTP' {
    BeforeAll {
        $script:testKey = 'embedding-SECRET-key-0123456789'
    }

    BeforeEach {
        Connect-AzFoundry -Endpoint 'https://lab.services.ai.azure.com' -ApiKey (New-TestSecureString $testKey)
    }

    It 'stops at the first failed batch with a mapped error' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 404 -Content (Get-TestFixture 'error-deployment-not-found.json')
        }
        $err = { 'a', 'b', 'c' | Invoke-AzFoundryEmbedding -Model 'nope' -BatchSize 1 } | Should -Throw -PassThru
        $err.FullyQualifiedErrorId | Should -BeLike '*,Invoke-AzFoundryEmbedding'
        $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
        Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
    }

    It 'calls the embeddings route and never logs the key in -Debug or -Verbose output' {
        Mock Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry {
            New-TestResponse -StatusCode 200 -Content (Get-TestFixture 'embedding-dimensions.json')
        }
        $output = Invoke-AzFoundryEmbedding -Model 'm' -InputText 'a' -Dimensions 256 -Verbose -Debug 4>&1 5>&1
        ($output | Out-String) | Should -Not -Match ([regex]::Escape($testKey))
        ($output | Where-Object { $_.PSObject.TypeNames[0] -eq 'PwshAzureFoundry.Embedding' }).Dimensions |
            Should -Be 256
        Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -ParameterFilter {
            $Uri -eq 'https://lab.services.ai.azure.com/openai/v1/embeddings'
        }
    }
}

Describe 'ConvertTo-AzFoundryEmbedding' {
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an index out of range'; Json = '{"data":[{"index":3,"embedding":[1]}]}'; Pattern = '*unexpected item index (3)*' }
        @{ Case = 'a duplicate index'; Json = '{"data":[{"index":0,"embedding":[1]},{"index":0,"embedding":[2]}]}'
            Pattern = '*unexpected item index (0)*' }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Json = $Json; Pattern = $Pattern } {
            param($Json, $Pattern)
            { ConvertTo-AzFoundryEmbedding -Response ($Json | ConvertFrom-Json) -Text 'a', 'b' } | Should -Throw $Pattern
        }
    }

    It 'numbers the outputs from -StartIndex' {
        InModuleScope PwshAzureFoundry {
            $response = '{"model":"m","data":[{"index":0,"embedding":[1,2,3]}]}' | ConvertFrom-Json
            $result = ConvertTo-AzFoundryEmbedding -Response $response -Text 'a' -StartIndex 32
            $result.Index | Should -Be 32
            $result.Dimensions | Should -Be 3
        }
    }
}
