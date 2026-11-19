#Requires -Version 7.4

<#
.SYNOPSIS
    Analyzes, tests, builds and publishes the PwshAzureFoundry module.
.DESCRIPTION
    Tasks run in the order given:

      Analyze  - PSScriptAnalyzer on src/ and build/ with PSScriptAnalyzerSettings.psd1. Fails on any finding.
      Test     - Pester 5 unit tests in test/Unit (the Integration tag is always excluded).
                 Writes build/output/testResults.xml (NUnit XML).
      Build    - Copies src/PwshAzureFoundry to build/output/PwshAzureFoundry/<version> and validates
                 the copied manifest.
      Publish  - Publishes the built module to the PowerShell Gallery. Needs -NuGetApiKey and a stable
                 version: the build refuses to publish a manifest with a Prerelease label.

    The default is Analyze, Test, Build.
.PARAMETER Task
    One or more tasks to run, in the order given.
.PARAMETER NuGetApiKey
    PowerShell Gallery API key, as a SecureString. Required by the Publish task.
.PARAMETER Repository
    Repository name for the Publish task. Defaults to PSGallery.
.EXAMPLE
    ./build/build.ps1

    Runs Analyze, Test and Build.
.EXAMPLE
    ./build/build.ps1 -Task Test

    Runs the unit tests only.
.EXAMPLE
    $key = ConvertTo-SecureString $env:PSGALLERY_API_KEY -AsPlainText -Force
    ./build/build.ps1 -Task Analyze, Test, Build, Publish -NuGetApiKey $key

    Full release pipeline, as run by the release workflow on a stable tag.
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Test', 'Build', 'Publish')]
    [string[]]$Task = @('Analyze', 'Test', 'Build'),

    [securestring]$NuGetApiKey,

    [ValidateNotNullOrEmpty()]
    [string]$Repository = 'PSGallery'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$moduleName   = 'PwshAzureFoundry'
$repoRoot     = Split-Path -Path $PSScriptRoot -Parent
$sourceDir    = Join-Path $repoRoot "src/$moduleName"
$manifestPath = Join-Path $sourceDir "$moduleName.psd1"
$outputRoot   = Join-Path $PSScriptRoot 'output'
$settingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'

$manifest      = Import-PowerShellDataFile -Path $manifestPath
$moduleVersion = $manifest.ModuleVersion
$prerelease    = $manifest.PrivateData.PSData['Prerelease']
$fullVersion   = if ($prerelease) { "$moduleVersion-$prerelease" } else { $moduleVersion }
$moduleOutDir  = Join-Path $outputRoot "$moduleName/$moduleVersion"

function Write-TaskHeader {
    param([string]$Name)
    Write-Information "`n=== $Name ($moduleName $fullVersion) ===" -InformationAction Continue
}

function Import-RequiredModule {
    param(
        [string]$Name,
        [version]$MinimumVersion
    )
    $available = Get-Module -ListAvailable -Name $Name |
        Where-Object Version -GE $MinimumVersion |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $available) {
        throw "$Name $MinimumVersion or later is required. Install it with: Install-PSResource $Name"
    }
    Import-Module $available -Force
}

function Invoke-AnalyzeTask {
    Write-TaskHeader 'Analyze'
    Import-RequiredModule -Name PSScriptAnalyzer -MinimumVersion '1.21.0'

    $findings = foreach ($path in @($sourceDir, $PSScriptRoot)) {
        Invoke-ScriptAnalyzer -Path $path -Recurse -Settings $settingsPath
    }
    $findings = @($findings | Where-Object { $_.ScriptPath -notlike "$outputRoot*" })

    if ($findings.Count -gt 0) {
        $findings |
            Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message |
            Out-String -Width 200 |
            Write-Information -InformationAction Continue
        throw "PSScriptAnalyzer reported $($findings.Count) finding(s)."
    }
    Write-Information 'Analyze: no findings.' -InformationAction Continue
}

function Invoke-TestTask {
    Write-TaskHeader 'Test'
    Import-RequiredModule -Name Pester -MinimumVersion '5.5.0'

    $null = New-Item -Path $outputRoot -ItemType Directory -Force

    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $repoRoot 'test/Unit'
    $config.Run.PassThru = $true
    $config.Filter.ExcludeTag = 'Integration'
    $config.Output.Verbosity = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $outputRoot 'testResults.xml'

    $result = Invoke-Pester -Configuration $config
    if ($result.Result -ne 'Passed') {
        throw "Pester: $($result.FailedCount) failed, $($result.FailedBlocksCount) failed block(s)."
    }
}

function Invoke-BuildTask {
    Write-TaskHeader 'Build'

    if (Test-Path -LiteralPath $moduleOutDir) {
        Remove-Item -LiteralPath $moduleOutDir -Recurse -Force
    }
    $null = New-Item -Path $moduleOutDir -ItemType Directory -Force

    Copy-Item -Path (Join-Path $sourceDir '*') -Destination $moduleOutDir -Recurse
    Get-ChildItem -LiteralPath $moduleOutDir -Recurse -File -Filter '.gitkeep' | Remove-Item -Force

    $null = Test-ModuleManifest -Path (Join-Path $moduleOutDir "$moduleName.psd1") -ErrorAction Stop
    Write-Information "Build: $moduleOutDir" -InformationAction Continue
}

function Invoke-PublishTask {
    param(
        [securestring]$ApiKey,
        [string]$TargetRepository
    )
    Write-TaskHeader 'Publish'

    if ($prerelease) {
        throw "Refusing to publish ${fullVersion}: pre-releases are never published to the Gallery (spec Q-5)."
    }
    if (-not $ApiKey) {
        throw 'The Publish task needs -NuGetApiKey.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $moduleOutDir "$moduleName.psd1"))) {
        throw "No built module at $moduleOutDir. Run the Build task first."
    }
    Import-RequiredModule -Name Microsoft.PowerShell.PSResourceGet -MinimumVersion '1.0.0'

    $plainKey = [System.Net.NetworkCredential]::new('', $ApiKey).Password
    try {
        Publish-PSResource -Path $moduleOutDir -Repository $TargetRepository -ApiKey $plainKey
    } finally {
        $plainKey = $null
    }
    Write-Information "Publish: $moduleName $fullVersion published to $TargetRepository." -InformationAction Continue
}

foreach ($name in $Task) {
    switch ($name) {
        'Analyze' { Invoke-AnalyzeTask }
        'Test' { Invoke-TestTask }
        'Build' { Invoke-BuildTask }
        'Publish' {
            Invoke-PublishTask -ApiKey $NuGetApiKey -TargetRepository $Repository
        }
    }
}
