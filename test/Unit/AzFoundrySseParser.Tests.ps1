#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule
    $script:streamText = Get-TestFixture 'chat-stream.txt'
}

Describe 'AzFoundrySseParser' {
    It 'parses chat-stream.txt in one chunk: 12 data events then [DONE]' {
        InModuleScope PwshAzureFoundry -Parameters @{ Text = $streamText } {
            param($Text)
            $parser = [AzFoundrySseParser]::new()
            $events = @($parser.Push($Text)) + @($parser.Flush())
            $events.Count | Should -Be 13
            $events[-1].Data | Should -Be '[DONE]'
            ($events[1].Data | ConvertFrom-Json).choices[0].delta.content | Should -Be 'Here'
            $events.Event | Select-Object -Unique | Should -Be 'message'
        }
    }

    It 'gives the same events when the text is split every <Size> characters' -ForEach @(
        @{ Size = 1 }, @{ Size = 3 }, @{ Size = 17 }, @{ Size = 1000 }
    ) {
        InModuleScope PwshAzureFoundry -Parameters @{ Text = $streamText; Size = $Size } {
            param($Text, $Size)
            $whole = [AzFoundrySseParser]::new()
            $expected = @($whole.Push($Text)) + @($whole.Flush())

            $parser = [AzFoundrySseParser]::new()
            $events = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $Text.Length; $i += $Size) {
                $piece = $Text.Substring($i, [math]::Min($Size, $Text.Length - $i))
                foreach ($e in $parser.Push($piece)) { $events.Add($e) }
            }
            foreach ($e in $parser.Flush()) { $events.Add($e) }

            $events.Count | Should -Be 13
            $events.Data | Should -Be $expected.Data
        }
    }

    It 'handles a CRLF split between two chunks, CR alone, comments and multi-line data' {
        InModuleScope PwshAzureFoundry {
            $parser = [AzFoundrySseParser]::new()
            $events = @(
                $parser.Push(": keep-alive`r`n`r`ndata: line one`r")
                $parser.Push("`ndata:line two`r`r")
                $parser.Push("event: error`ndata: {`"error`":{}}`n`n")
            )
            $events.Count | Should -Be 2
            $events[0].Data | Should -Be "line one`nline two"
            $events[0].Event | Should -Be 'message'
            $events[1].Event | Should -Be 'error'
            $events[1].Data | Should -Be '{"error":{}}'
        }
    }

    It 'ignores id and retry fields and events with no data' {
        InModuleScope PwshAzureFoundry {
            $parser = [AzFoundrySseParser]::new()
            @($parser.Push("id: 1`nretry: 100`n`nevent: ping`n`n")).Count | Should -Be 0
        }
    }

    It 'returns the last event on Flush when the stream does not end with a blank line' {
        InModuleScope PwshAzureFoundry {
            $parser = [AzFoundrySseParser]::new()
            @($parser.Push('data: [DONE]')).Count | Should -Be 0
            $last = @($parser.Flush())
            $last.Count | Should -Be 1
            $last[0].Data | Should -Be '[DONE]'
        }
    }
}
