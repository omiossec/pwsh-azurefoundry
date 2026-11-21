#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Runs the integration tests against a real Foundry resource and records the results.
.DESCRIPTION
    Runs test/Integration (tag Integration) with the settings from the AZURE_FOUNDRY_* environment variables (see
    README.md in this folder) and writes two files to -OutputPath:

      <yyyyMMdd-HHmmss>.md    summary: environment, totals, one line per test, failure messages (commit it)
      <yyyyMMdd-HHmmss>.xml   NUnit report (git-ignored)

    The summary is sanitised: the endpoint host, account, resource group, subscription id, any GUID and the API
    key are replaced by placeholders, so it can be committed.

    The tests create deployments named pwshit-* and delete them at the end, even when a test fails.
.PARAMETER OutputPath
    Folder for the results. Defaults to test/Integration/results.
.PARAMETER Path
    Test files to run. Defaults to every *.Integration.Tests.ps1 in this folder.
.EXAMPLE
    Connect-AzAccount
    $env:AZURE_FOUNDRY_ENDPOINT = 'https://<resource>.services.ai.azure.com'
    $env:AZURE_FOUNDRY_API_KEY  = Read-Host 'Key' -MaskInput
    $env:AZURE_FOUNDRY_RG = 'rg-lab'; $env:AZURE_FOUNDRY_ACCOUNT = '<resource>'
    ./test/Integration/Invoke-IntegrationTest.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'results'),

    [string[]]$Path = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Integration.Tests.ps1').FullName
)

$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Path $OutputPath -Force
$stamp = '{0:yyyyMMdd-HHmmss}' -f [datetime]::UtcNow
$xmlPath = Join-Path $OutputPath "$stamp.xml"
$summaryPath = Join-Path $OutputPath "$stamp.md"

foreach ($variable in 'AZURE_FOUNDRY_ENDPOINT', 'AZURE_FOUNDRY_API_KEY', 'AZURE_FOUNDRY_RG', 'AZURE_FOUNDRY_ACCOUNT') {
    if (-not [Environment]::GetEnvironmentVariable($variable)) {
        Write-Warning "$variable is not set: the tests that need it are skipped."
    }
}

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Filter.Tag = 'Integration'
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $xmlPath
$result = Invoke-Pester -Configuration $config

# Placeholders for everything that identifies the resource or the user.
$secrets = [ordered]@{}
if ($env:AZURE_FOUNDRY_API_KEY) { $secrets[$env:AZURE_FOUNDRY_API_KEY] = '<key>' }
if ($env:AZURE_FOUNDRY_ENDPOINT) {
    $hostName = ([uri]$env:AZURE_FOUNDRY_ENDPOINT).Host
    $secrets[$hostName.Split('.')[0]] = '<resource>'
}
if ($env:AZURE_FOUNDRY_ACCOUNT) { $secrets[$env:AZURE_FOUNDRY_ACCOUNT] = '<resource>' }
if ($env:AZURE_FOUNDRY_RG) { $secrets[$env:AZURE_FOUNDRY_RG] = '<resource-group>' }
if ($env:AZURE_FOUNDRY_SUBSCRIPTION_ID) { $secrets[$env:AZURE_FOUNDRY_SUBSCRIPTION_ID] = '<subscription-id>' }
$clean = {
    param([string]$Text)
    foreach ($key in $secrets.Keys) {
        $Text = $Text -replace [regex]::Escape($key), $secrets[$key]
    }
    $Text = $Text -replace '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}', '<guid>'
    ($Text -replace '\|', '\|') -replace '\r?\n', ' '
}

$module = Import-PowerShellDataFile (Join-Path $PSScriptRoot '../../src/PwshAzureFoundry/PwshAzureFoundry.psd1')
$commit = (git -C $PSScriptRoot rev-parse --short HEAD 2>$null)
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Integration run $stamp (UTC)")
$lines.Add('')
$lines.Add('| Item | Value |')
$lines.Add('|---|---|')
$lines.Add("| Module | $($module.ModuleVersion)-$($module.PrivateData.PSData.Prerelease) (commit $commit) |")
$lines.Add("| PowerShell | $($PSVersionTable.PSVersion) on $($PSVersionTable.OS) |")
$lines.Add("| Pester | $((Get-Module Pester).Version) |")
$models = foreach ($pair in @(
        , @($env:AZURE_FOUNDRY_CHAT_MODEL, 'Mistral-Large-3')
        , @($env:AZURE_FOUNDRY_DECISION_MODEL, 'Decision-1.1')
        , @($env:AZURE_FOUNDRY_EMBEDDING_MODEL, 'text-embedding-3-small'))) {
    if ($pair[0]) { $pair[0] } else { $pair[1] }
}
$lines.Add("| Chat / decision / embedding | $($models -join ' / ') |")
. (Join-Path $PSScriptRoot 'IntegrationHelpers.ps1')
$setting = Get-ItSetting
$yesNo = { param([bool]$Value) if ($Value) { 'yes' } else { 'no (skipped)' } }
$lines.Add("| Settings | key: $(& $yesNo $setting.HasKey); Az context: $(& $yesNo $setting.HasAzContext); " +
    "management: $(& $yesNo $setting.HasArm); partner model: $(& $yesNo ([bool]$setting.AsyncModel)) |")
$totals = '{0} passed, {1} failed, {2} skipped, {3} not run, in {4:N0} s' -f $result.PassedCount,
$result.FailedCount, $result.SkippedCount, $result.NotRunCount, $result.Duration.TotalSeconds
$lines.Add("| Result | **$($result.Result)**: $totals |")
$lines.Add('')
$lines.Add('| Result | Test | Duration |')
$lines.Add('|---|---|---|')
foreach ($test in $result.Tests) {
    $testName = & $clean $test.ExpandedPath
    $lines.Add(('| {0} | {1} | {2:N1} s |' -f $test.Result, $testName, $test.Duration.TotalSeconds))
}
$failed = @($result.Tests | Where-Object Result -EQ 'Failed')
if ($failed) {
    $lines.Add('')
    $lines.Add('## Failures')
    foreach ($test in $failed) {
        $lines.Add('')
        $lines.Add("- **$(& $clean $test.ExpandedPath)**: $(& $clean ([string]$test.ErrorRecord[0].Exception.Message))")
    }
}
$lines.Add('')
$lines.Add('## Notes')
$lines.Add('')
$lines.Add('<!-- Add what the run showed: timings, service behaviour, follow-ups. -->')
Set-Content -LiteralPath $summaryPath -Value $lines -Encoding utf8

Write-Information "Summary: $summaryPath" -InformationAction Continue
Write-Information "NUnit:   $xmlPath" -InformationAction Continue
if ($result.Result -ne 'Passed') {
    exit 1
}
