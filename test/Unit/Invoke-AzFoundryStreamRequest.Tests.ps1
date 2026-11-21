#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    # Fake HttpMessageHandler: no network. Each queued response streams its body a few bytes per read.
    if (-not ('AzFoundryTestHandler' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class AzFoundryTestChunkedStream : MemoryStream {
    private readonly int _chunk;
    public bool IsDisposed;
    public AzFoundryTestChunkedStream(byte[] bytes, int chunk) : base(bytes) { _chunk = chunk; }
    public override int Read(byte[] buffer, int offset, int count) {
        return base.Read(buffer, offset, Math.Min(count, _chunk));
    }
    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken ct) {
        return base.ReadAsync(buffer, offset, Math.Min(count, _chunk), ct);
    }
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct) {
        return base.ReadAsync(buffer.Slice(0, Math.Min(buffer.Length, _chunk)), ct);
    }
    protected override void Dispose(bool disposing) { IsDisposed = true; base.Dispose(disposing); }
}

public class AzFoundryTestHandler : HttpMessageHandler {
    private readonly Queue<Tuple<int, string, int, string[]>> _responses = new Queue<Tuple<int, string, int, string[]>>();
    public readonly List<HttpRequestMessage> Requests = new List<HttpRequestMessage>();
    public readonly List<string> Bodies = new List<string>();
    public readonly List<AzFoundryTestChunkedStream> Streams = new List<AzFoundryTestChunkedStream>();
    public bool IsDisposed;

    public void Enqueue(int status, string body, int chunk, string[] headers) {
        _responses.Enqueue(Tuple.Create(status, body, chunk, headers ?? new string[0]));
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) {
        Requests.Add(request);
        Bodies.Add(request.Content == null ? null : await request.Content.ReadAsStringAsync());
        var next = _responses.Dequeue();
        var stream = new AzFoundryTestChunkedStream(Encoding.UTF8.GetBytes(next.Item2), next.Item3);
        Streams.Add(stream);
        var response = new HttpResponseMessage((HttpStatusCode)next.Item1) { Content = new StreamContent(stream) };
        response.Content.Headers.TryAddWithoutValidation("Content-Type", "text/event-stream");
        for (int i = 0; i + 1 < next.Item4.Length; i += 2) {
            response.Headers.TryAddWithoutValidation(next.Item4[i], next.Item4[i + 1]);
        }
        return response;
    }

    protected override void Dispose(bool disposing) { IsDisposed = true; base.Dispose(disposing); }
}
'@
    }

    $script:testKey = 'stream-SECRET-key-0123456789'
    $script:streamText = Get-TestFixture 'chat-stream.txt'

    function New-TestHandler {
        $handler = [AzFoundryTestHandler]::new()
        Mock New-AzFoundryHttpClient -ModuleName PwshAzureFoundry {
            [System.Net.Http.HttpClient]::new($handler, $true)
        }.GetNewClosure()
        $handler
    }

    function Invoke-TestStream {
        param([hashtable]$Headers)
        InModuleScope PwshAzureFoundry -Parameters @{ Key = $testKey; Headers = $Headers } {
            param($Key, $Headers)
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
            $connection.ApiKey = ConvertTo-SecureString $Key -AsPlainText -Force
            $parameters = @{
                Connection = $connection
                Path       = '/openai/v1/chat/completions'
                Body       = [ordered]@{ model = 'm'; stream = $true }
            }
            if ($null -ne $Headers) { $parameters['ResponseHeaders'] = $Headers }
            Invoke-AzFoundryStreamRequest @parameters
        }
    }
}

Describe 'Invoke-AzFoundryStreamRequest' {
    It 'outputs every JSON chunk of chat-stream.txt read 5 bytes at a time, and stops at [DONE]' {
        $handler = New-TestHandler
        $handler.Enqueue(200, $streamText + "data: {`"after`":`"done`"}`n`n", 5, $null)

        $chunks = @(Invoke-TestStream)
        $chunks.Count | Should -Be 12
        $chunks[1].choices[0].delta.content | Should -Be 'Here'
        $chunks[-1].usage.total_tokens | Should -Be 53
    }

    It 'sends a POST with the JSON body, the api-key, Accept and User-Agent headers' {
        $handler = New-TestHandler
        $handler.Enqueue(200, "data: [DONE]`n`n", 100, $null)
        $null = Invoke-TestStream

        $request = $handler.Requests[0]
        $request.Method.Method | Should -Be 'POST'
        $request.RequestUri.AbsoluteUri | Should -Be 'https://lab.services.ai.azure.com/openai/v1/chat/completions'
        @($request.Headers.GetValues('api-key')) | Should -Be @($testKey)
        @($request.Headers.GetValues('Accept')) | Should -Be @('text/event-stream')
        ($request.Headers.UserAgent -join ' ') | Should -Match 'PwshAzureFoundry/'
        $handler.Bodies[0] | Should -Be '{"model":"m","stream":true}'
    }

    It 'fills -ResponseHeaders with the response headers' {
        $handler = New-TestHandler
        $handler.Enqueue(200, "data: [DONE]`n`n", 100, @('x-ratelimit-remaining-requests', '18'))
        $headers = @{}
        $null = Invoke-TestStream -Headers $headers
        $headers['x-ratelimit-remaining-requests'] | Should -Be '18'
    }

    It 'disposes the client and the response stream' {
        $handler = New-TestHandler
        $handler.Enqueue(200, $streamText, 50, $null)
        $null = Invoke-TestStream
        $handler.IsDisposed | Should -BeTrue
        $handler.Streams[0].IsDisposed | Should -BeTrue
    }

    It 'disposes everything when the pipeline is stopped early' {
        $handler = New-TestHandler
        $handler.Enqueue(200, $streamText, 50, $null)
        $first = @(Invoke-TestStream | Select-Object -First 1)
        $first.Count | Should -Be 1
        $handler.IsDisposed | Should -BeTrue
        $handler.Streams[0].IsDisposed | Should -BeTrue
    }

    It 'ends cleanly when the stream closes without [DONE]' {
        $handler = New-TestHandler
        $handler.Enqueue(200, 'data: {"id":"x","choices":[]}', 100, $null)
        @(Invoke-TestStream).Count | Should -Be 1
    }

    It 'maps an HTTP error before the stream to an ErrorRecord without the key' {
        $handler = New-TestHandler
        $handler.Enqueue(404, (Get-TestFixture 'error-deployment-not-found.json'), 100, $null)
        $err = { Invoke-TestStream } | Should -Throw -PassThru
        $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
        $err.FullyQualifiedErrorId | Should -BeLike 'AzFoundry.DeploymentNotFound*'
        $err.ToString() | Should -Not -Match ([regex]::Escape($testKey))
        $handler.IsDisposed | Should -BeTrue
    }

    It 'retries a 429 and honours Retry-After' {
        Mock Start-Sleep -ModuleName PwshAzureFoundry {}
        $handler = New-TestHandler
        $handler.Enqueue(429, (Get-TestFixture 'synthetic-error-429.json'), 100, @('Retry-After', '6'))
        $handler.Enqueue(200, $streamText, 100, $null)

        @(Invoke-TestStream).Count | Should -Be 12
        $handler.Requests.Count | Should -Be 2
        Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 1 -ParameterFilter { $Milliseconds -eq 6000 }
    }

    It 'does not retry a 5xx: the inference may already have run and been billed' {
        Mock Start-Sleep -ModuleName PwshAzureFoundry {}
        $handler = New-TestHandler
        $handler.Enqueue(503, '{"error":{"code":"ServiceUnavailable","message":"busy"}}', 100, $null)
        $handler.Enqueue(200, $streamText, 100, $null)

        { Invoke-TestStream } | Should -Throw
        $handler.Requests.Count | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 0 -Exactly
    }

    It 'throws on an error payload in the stream, after the chunks already received' {
        $handler = New-TestHandler
        $errorEvent = 'data: ' + ((Get-TestFixture 'synthetic-error-content-filter-400.json') -replace '\s*\r?\n\s*', '')
        $firstSeven = @($streamText -split "`r?`n" | Where-Object { $_ -like 'data: {*' })[0..6]
        $handler.Enqueue(200, (($firstSeven + $errorEvent) -join "`n`n") + "`n`n", 7, $null)

        $received = [System.Collections.Generic.List[object]]::new()
        $err = { Invoke-TestStream | ForEach-Object { $received.Add($_) } } | Should -Throw -PassThru
        $received.Count | Should -Be 7
        $err.CategoryInfo.Category | Should -Be 'SecurityError'
        $err.FullyQualifiedErrorId | Should -BeLike 'AzFoundry.content_filter*'
    }

    It 'throws on an SSE error event' {
        $handler = New-TestHandler
        $handler.Enqueue(200, "event: error`ndata: {`"error`":{`"code`":`"server_error`",`"message`":`"boom`"}}`n`n", 100, $null)
        $err = { Invoke-TestStream } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'HTTP 500 \(server_error\): boom'
        $err.CategoryInfo.Category | Should -Be 'ResourceUnavailable'
    }

    It 'skips a non-JSON event with a warning' {
        $handler = New-TestHandler
        $handler.Enqueue(200, "data: not json`n`ndata: {`"id`":`"x`"}`n`ndata: [DONE]`n`n", 100, $null)
        $output = @(Invoke-TestStream 3>&1)
        $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        $chunks = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        $chunks.Count | Should -Be 1
        $warnings.Count | Should -Be 1
        $warnings[0].Message | Should -Match 'not JSON'
    }

    It 'maps a transport failure to AzFoundryConnectionFailed' {
        # A handler with an empty queue throws InvalidOperationException, like a failed send.
        $null = New-TestHandler
        { Invoke-TestStream } | Should -Throw -ErrorId 'AzFoundryConnectionFailed*'
    }

    It 'never writes the key in -Verbose or -Debug output' {
        $handler = New-TestHandler
        $handler.Enqueue(200, $streamText, 100, $null)
        $output = InModuleScope PwshAzureFoundry -Parameters @{ Key = $testKey } {
            param($Key)
            $connection = [AzFoundryConnection]::new('https://lab.services.ai.azure.com', 'ApiKey')
            $connection.ApiKey = ConvertTo-SecureString $Key -AsPlainText -Force
            Invoke-AzFoundryStreamRequest -Connection $connection -Path '/openai/v1/chat/completions' `
                -Body @{ model = 'm' } -Verbose -Debug 4>&1 5>&1
        }
        $text = $output | Out-String
        $text | Should -Match 'api-key: \*\*\*'
        $text | Should -Match '\(stream\)'
        $text | Should -Not -Match ([regex]::Escape($testKey))
    }
}

Describe 'Invoke-AzFoundryStreamRequest timeouts' {
    It 'maps a timeout <Stage> to AzFoundryRequestTimeout' -ForEach @(
        @{ Stage = 'waiting for the response'; Pattern = 'POST*' }
        @{ Stage = 'reading the stream'; Pattern = 'Reading the stream*' }
    ) {
        $handler = New-TestHandler
        $handler.Enqueue(200, $streamText, 100, $null)
        Mock Wait-AzFoundryTask -ModuleName PwshAzureFoundry -ParameterFilter { $Operation -like $Pattern } {
            throw [System.TimeoutException]::new('timed out')
        }
        $err = { Invoke-TestStream } | Should -Throw -ErrorId 'AzFoundryRequestTimeout*' -PassThru
        $err.Exception.Message | Should -Match ([regex]::Escape("($Stage)"))
        $err.ErrorDetails.RecommendedAction | Should -Match 'TimeoutSec'
        $handler.IsDisposed | Should -BeTrue
    }
}

Describe 'New-AzFoundryHttpClient' {
    It 'does not follow redirects and sets the timeouts' {
        InModuleScope PwshAzureFoundry {
            $client = New-AzFoundryHttpClient -TimeoutSec 42
            try {
                $client.Timeout.TotalSeconds | Should -Be 42
                $handlerField = [System.Net.Http.HttpMessageInvoker].GetField('_handler',
                    [System.Reflection.BindingFlags]'NonPublic, Instance')
                $handler = $handlerField.GetValue($client)
                $handler.AllowAutoRedirect | Should -BeFalse
                $handler.ConnectTimeout.TotalSeconds | Should -Be 42
            } finally {
                $client.Dispose()
            }
        }
    }
}

Describe 'Wait-AzFoundryTask' {
    It 'returns the result of a completed task' {
        InModuleScope PwshAzureFoundry {
            Wait-AzFoundryTask -Task ([System.Threading.Tasks.Task]::FromResult(42)) | Should -Be 42
        }
    }

    It 'throws a TimeoutException when the task does not complete in time' {
        InModuleScope PwshAzureFoundry {
            $never = [System.Threading.Tasks.TaskCompletionSource[int]]::new().Task
            { Wait-AzFoundryTask -Task $never -TimeoutSec 1 -Operation 'POST x' } |
                Should -Throw -ExceptionType ([System.TimeoutException]) -ExpectedMessage 'POST x timed out after 1 s.'
        }
    }

    It 'rethrows the exception of a faulted task' {
        InModuleScope PwshAzureFoundry {
            $failed = [System.Threading.Tasks.Task]::FromException([System.IO.IOException]::new('broken'))
            { Wait-AzFoundryTask -Task $failed } | Should -Throw -ExceptionType ([System.IO.IOException])
        }
    }
}
