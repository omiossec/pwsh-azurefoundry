#Requires -Version 7.4
<#
.SYNOPSIS
    Copies raw spike captures to test/Fixtures with identifying data scrubbed.
.DESCRIPTION
    Replaces GUIDs (subscription, tenant, principal, request ids), e-mail addresses, the resource
    group and account names, and any value under a key/token-like property name. Fails if the
    output still contains a GUID-looking subscription path or a 32+ char hex/base64 secret.
.EXAMPLE
    ./test/Spikes/ConvertTo-SanitizedFixture.ps1 -SourcePath $env:TEMP/spike -AccountName <account> `
        -ResourceGroupName <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourcePath,
    [Parameter(Mandatory)] [string] $AccountName,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [string[]] $ProjectName = @(),
    [string] $DestinationPath = (Join-Path $PSScriptRoot '..' 'Fixtures'),
    [string[]] $Include = '*'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null

$guid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$rules = [ordered]@{
    $guid                                                   = '00000000-0000-0000-0000-000000000000'
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'        = 'user@example.com'
    [regex]::Escape($AccountName)                           = 'test-foundry'
    [regex]::Escape($ResourceGroupName)                     = 'rg-test'
}
foreach ($p in $ProjectName) { $rules[[regex]::Escape($p)] = "test-project" }
$rules['("(key1|key2|api-key|token|access_token|primaryKey|secondaryKey)"\s*:\s*)"[^"]*"'] = '$1"<redacted>"'

Get-ChildItem -Path $SourcePath -File -Include $Include -Recurse | ForEach-Object {
    $text = Get-Content -Path $_.FullName -Raw
    foreach ($pattern in $rules.Keys) { $text = $text -replace $pattern, $rules[$pattern] }

    if ($text -match '/subscriptions/(?!00000000-0000-0000-0000-000000000000)') {
        throw "Unscrubbed subscription id left in $($_.Name)"
    }
    if ($text -match '(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])' -and $_.Name -like 'arm-listKeys*') {
        throw "Possible key left in $($_.Name)"
    }
    $target = Join-Path $DestinationPath $_.Name
    Set-Content -Path $target -Value $text -NoNewline
    Write-Verbose "Sanitised $($_.Name)"
}
