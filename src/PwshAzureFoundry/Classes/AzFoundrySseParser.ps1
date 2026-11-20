#Requires -Version 7.4

# Incremental Server-Sent Events parser (used by Invoke-AzFoundryStreamRequest).
#
# Push() takes text as it arrives, in chunks of any size (a chunk may end in the middle of a line or of a
# CRLF pair), and returns the events completed by that chunk. Flush() ends the stream and returns the last
# event when the stream did not end with a blank line.
#
# Rules (WHATWG SSE): lines end with CRLF, LF or CR; a blank line dispatches the event; lines starting with
# ':' are comments (keep-alive) and are ignored; 'data' lines of one event are joined with LF; one space
# after the colon is removed; 'event' sets the event type. 'id' and 'retry' are ignored. An event with no
# data line is dropped.
class AzFoundrySseParser {
    hidden [System.Text.StringBuilder] $Line = [System.Text.StringBuilder]::new()
    hidden [System.Collections.Generic.List[string]] $Data = [System.Collections.Generic.List[string]]::new()
    hidden [string] $EventType
    hidden [bool] $SkipLineFeed

    [object[]] Push([string]$text) {
        $events = [System.Collections.Generic.List[object]]::new()
        if ([string]::IsNullOrEmpty($text)) {
            return $events.ToArray()
        }
        foreach ($character in $text.ToCharArray()) {
            if ($this.SkipLineFeed) {
                $this.SkipLineFeed = $false
                if ($character -eq "`n") {
                    continue
                }
            }
            if ($character -eq "`r" -or $character -eq "`n") {
                $this.SkipLineFeed = $character -eq "`r"
                $completed = $this.ProcessLine($this.Line.ToString())
                [void]$this.Line.Clear()
                if ($null -ne $completed) {
                    $events.Add($completed)
                }
            } else {
                [void]$this.Line.Append($character)
            }
        }
        return $events.ToArray()
    }

    [object[]] Flush() {
        $events = [System.Collections.Generic.List[object]]::new()
        if ($this.Line.Length -gt 0) {
            $completed = $this.ProcessLine($this.Line.ToString())
            [void]$this.Line.Clear()
            if ($null -ne $completed) {
                $events.Add($completed)
            }
        }
        $last = $this.ProcessLine('')
        if ($null -ne $last) {
            $events.Add($last)
        }
        return $events.ToArray()
    }

    # Returns the event dispatched by a blank line, or $null.
    hidden [object] ProcessLine([string]$line) {
        if ($line.Length -eq 0) {
            if ($this.Data.Count -eq 0) {
                $this.EventType = $null
                return $null
            }
            $completed = [pscustomobject]@{
                PSTypeName = 'PwshAzureFoundry.SseEvent'
                Event      = if ($this.EventType) { $this.EventType } else { 'message' }
                Data       = $this.Data -join "`n"
            }
            $this.Data.Clear()
            $this.EventType = $null
            return $completed
        }
        if ($line[0] -eq ':') {
            return $null
        }

        $colon = $line.IndexOf(':')
        if ($colon -lt 0) {
            $field = $line
            $value = ''
        } else {
            $field = $line.Substring(0, $colon)
            $value = $line.Substring($colon + 1)
            if ($value.StartsWith(' ')) {
                $value = $value.Substring(1)
            }
        }
        switch ($field) {
            'data' { $this.Data.Add($value) }
            'event' { $this.EventType = $value }
        }
        return $null
    }
}
