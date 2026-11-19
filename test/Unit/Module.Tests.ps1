#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeDiscovery {
    $moduleRoot    = Join-Path $PSScriptRoot '../../src/PwshAzureFoundry'
    $publicScripts = @(Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1' -File -ErrorAction Ignore)
    $publicCases   = @($publicScripts | ForEach-Object { @{ Name = $_.BaseName; Path = $_.FullName } })
}

BeforeAll {
    $moduleRoot   = Join-Path $PSScriptRoot '../../src/PwshAzureFoundry'
    $manifestPath = Join-Path $moduleRoot 'PwshAzureFoundry.psd1'
    $manifestData = Import-PowerShellDataFile -Path $manifestPath
    Get-Module PwshAzureFoundry | Remove-Module -Force
    $module = Import-Module $manifestPath -Force -PassThru
    $publicNames = @(
        Get-ChildItem -Path (Join-Path $moduleRoot 'Public') -Filter '*.ps1' -File -ErrorAction Ignore |
            Select-Object -ExpandProperty BaseName
    )
}

AfterAll {
    Get-Module PwshAzureFoundry | Remove-Module -Force
}

Describe 'Module manifest' {
    It 'is a valid manifest' {
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'requires PowerShell 7.4 on Core' {
        $manifestData.PowerShellVersion | Should -Be '7.4'
        $manifestData.CompatiblePSEditions | Should -Be @('Core')
    }

    It 'has Gallery metadata' {
        $psData = $manifestData.PrivateData.PSData
        $psData.Tags | Should -Not -BeNullOrEmpty
        $psData.ProjectUri | Should -Match '^https://'
        $psData.LicenseUri | Should -Match '^https://'
        $manifestData.Description | Should -Not -BeNullOrEmpty
    }

    It 'declares the format file and it exists' {
        $manifestData.FormatsToProcess | Should -Contain 'PwshAzureFoundry.Format.ps1xml'
        Join-Path $moduleRoot 'PwshAzureFoundry.Format.ps1xml' | Should -Exist
    }

    It 'lists exports explicitly (no wildcards)' {
        foreach ($key in 'FunctionsToExport', 'CmdletsToExport', 'VariablesToExport', 'AliasesToExport') {
            $manifestData.ContainsKey($key) | Should -BeTrue -Because "$key must be declared"
            @($manifestData[$key]) -join ',' | Should -Not -Match '\*' -Because "$key must not use wildcards"
        }
    }

    It 'exports exactly the functions in Public/' {
        $expected = @($publicNames | Sort-Object)
        $declared = @($manifestData.FunctionsToExport | Sort-Object)
        $exported = @($module.ExportedFunctions.Keys | Sort-Object)

        $declared | Should -Be $expected
        $exported | Should -Be $expected
    }

    It 'exports no aliases, cmdlets or variables' {
        $module.ExportedAliases.Count | Should -Be 0
        $module.ExportedCmdlets.Count | Should -Be 0
        $module.ExportedVariables.Count | Should -Be 0
    }
}

Describe 'Public function <Name>' -ForEach $publicCases {
    BeforeAll {
        $command = Get-Command -Module PwshAzureFoundry -Name $Name -CommandType Function -ErrorAction Ignore

        # Read comment-based help from the source: Get-Help invents a synopsis and an example
        # for functions that have no help, so it cannot detect missing help.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $isFunction = { $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }
        $functions = @($ast.FindAll($isFunction, $false))
        $help = if ($functions.Count -eq 1) { $functions[0].GetHelpContent() }
    }

    It 'is defined by a single function of the same name in its file' {
        @($functions.Name) | Should -Be @($Name)
    }

    It 'is exported' {
        $command | Should -Not -BeNullOrEmpty
    }

    It 'uses an approved verb' {
        (Get-Verb).Verb | Should -Contain $command.Verb
    }

    It 'uses the AzFoundry noun prefix' {
        $command.Noun | Should -BeLike 'AzFoundry*'
    }

    It 'has [CmdletBinding()]' {
        $command.CmdletBinding | Should -BeTrue
    }

    It 'has comment-based help' {
        $help | Should -Not -BeNullOrEmpty
    }

    It 'has a synopsis' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
    }

    It 'has a description' {
        $help.Description | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        $help.Examples.Count | Should -BeGreaterThan 0
    }

    It 'documents every parameter' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                  [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $documented = @($help.Parameters.Keys)
        foreach ($parameter in $command.Parameters.Keys | Where-Object { $_ -notin $common }) {
            $documented | Should -Contain $parameter.ToUpperInvariant() -Because "-$parameter needs a .PARAMETER entry"
        }
    }
}
