#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the dev.to article snippets (samples/article/*.ps1) in order against a real Foundry resource.
.DESCRIPTION
    The snippets use plain REST (Az.Accounts and Invoke-RestMethod, no PwshAzureFoundry). They share variables,
    so they are dot-sourced one after the other in a single runspace, as a reader pasting them in one session
    would. A test fails when its snippet throws or writes an error.

    Needs Connect-AzAccount, AZURE_FOUNDRY_RG and AZURE_FOUNDRY_ACCOUNT, a chat deployment and a decision
    deployment on the resource, and the Cognitive Services Contributor role (08-deploy.ps1 creates the
    'article-embedding' deployment; 09-cleanup.ps1 and AfterAll delete it).

    Then samples/article-teaser.ps1, the article's closing block, runs in a child pwsh with PwshAzureFoundry
    downloaded from the PowerShell Gallery (the version pinned in the article), never the repository copy.
.EXAMPLE
    Connect-AzAccount
    $env:AZURE_FOUNDRY_RG = 'rg-lab'; $env:AZURE_FOUNDRY_ACCOUNT = '<resource>'
    Invoke-Pester ./test/Integration/Article.Tests.ps1 -Tag Article -Output Detailed
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'BeforeDiscovery variables are used by -ForEach and -Skip.')]
param()

BeforeDiscovery {
    $snippets = @(Get-ChildItem -Path (Join-Path $PSScriptRoot '../../samples/article') -Filter '*.ps1' |
            Sort-Object Name | ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $skip = -not ($env:AZURE_FOUNDRY_RG -and $env:AZURE_FOUNDRY_ACCOUNT)
}

Describe 'Article snippets' -Tag 'Integration', 'Article' -Skip:$skip {
    BeforeAll {
        $script:runspace = [runspacefactory]::CreateRunspace()
        $script:runspace.Open()
        $script:failed = $false

        function Invoke-Snippet {
            param([Parameter(Mandatory)] [string] $Script)

            $ps = [powershell]::Create()
            $ps.Runspace = $script:runspace
            try {
                $null = $ps.AddScript($Script)
                $output = $ps.Invoke()
                $errors = @($ps.Streams.Error)
                if ($errors.Count -gt 0) { throw $errors[0] }
                $output | Out-String -Width 160 | Write-Information -InformationAction Continue
            } finally {
                $ps.Dispose()
            }
        }

        Invoke-Snippet -Script '$ErrorActionPreference = "Stop"; Import-Module Az.Accounts'
    }

    AfterAll {
        # Delete the deployment of 08-deploy.ps1 even when a test failed (DELETE is idempotent).
        try {
            Invoke-Snippet -Script @'
if ($deploymentUri -and $armToken) {
    Invoke-RestMethod -Method Delete -Uri $deploymentUri -Authentication Bearer -Token $armToken
}
'@
        } catch {
            Write-Warning "Could not delete the article-embedding deployment: $_"
        }
        $script:runspace.Dispose()
    }

    It '<Name> runs without error' -ForEach $snippets {
        if ($script:failed) { Set-ItResult -Skipped -Because 'a previous snippet failed' }
        try {
            Invoke-Snippet -Script ". '$($Path -replace "'", "''")'"
        } catch {
            $script:failed = $true
            throw
        }
    }

    It 'leaves no secret in the session after the cleanup' {
        if ($script:failed) { Set-ItResult -Skipped -Because 'a previous snippet failed' }
        $ps = [powershell]::Create()
        $ps.Runspace = $script:runspace
        try {
            $null = $ps.AddScript('[bool](Get-Variable apiKey, armToken -ErrorAction Ignore)')
            $ps.Invoke() | Should -BeFalse
        } finally {
            $ps.Dispose()
        }
    }
}

Describe 'Article module teaser' -Tag 'Integration', 'Article' -Skip:$skip {
    BeforeAll {
        $script:galleryVersion = '0.1.0'   # the version pinned in the article and in article-teaser.ps1
        $script:teaser = (Resolve-Path (Join-Path $PSScriptRoot '../../samples/article-teaser.ps1')).Path
    }

    It 'pins the same module version as this test' {
        Get-Content -LiteralPath $script:teaser -Raw |
            Should -Match ([regex]::Escape("Install-PSResource PwshAzureFoundry -Version $script:galleryVersion"))
    }

    It 'runs against PwshAzureFoundry from the PowerShell Gallery' {
        $modulePath = Join-Path $TestDrive 'gallery'
        $null = New-Item -Path $modulePath -ItemType Directory
        Save-PSResource -Name PwshAzureFoundry -Version $script:galleryVersion -Repository PSGallery `
            -Path $modulePath -TrustRepository -Quiet

        # A child process, so that a repository copy loaded in this session cannot be picked up
        $output = & pwsh -NoProfile -NonInteractive -Command {
            param($ModulePath, $Script)
            $ErrorActionPreference = 'Stop'
            $env:PSModulePath = $ModulePath + [IO.Path]::PathSeparator + $env:PSModulePath
            & $Script
            "ModuleBase=$((Get-Module PwshAzureFoundry).ModuleBase)"
        } -args $modulePath, $script:teaser 2>&1
        $text = $output | Out-String -Width 160
        $text | Write-Information -InformationAction Continue

        $LASTEXITCODE | Should -Be 0 -Because $text
        $base = $output | Where-Object { "$_" -like 'ModuleBase=*' } | Select-Object -Last 1
        "$base" -replace '^ModuleBase=', '' | Should -BeLike "$modulePath*"
    }
}
