#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:schema = [ordered]@{
        type       = 'object'
        properties = [ordered]@{ city = [ordered]@{ type = 'string'; description = 'City name' } }
        required   = @('city')
    }
}

Describe 'New-AzFoundryTool' {
    It 'builds a function tool in the wire shape' {
        $tool = New-AzFoundryTool -Name 'get_weather' -Description 'Current weather for a city' -Parameter $schema
        $tool.GetType().Name | Should -Be 'AzFoundryTool'
        ($tool.ToHashtable() | ConvertTo-Json -Depth 10 -Compress) | Should -Be (
            '{"type":"function","function":{"name":"get_weather","description":"Current weather for a city",' +
            '"parameters":{"type":"object","properties":{"city":{"type":"string","description":"City name"}},' +
            '"required":["city"]}}}')
    }

    It 'omits parameters for a tool with no arguments' {
        $hash = (New-AzFoundryTool -Name 'get_time' -Description 'UTC time').ToHashtable()
        $hash.function.Keys | Should -Be @('name', 'description')
    }

    It 'rejects an invalid name: <Name>' -ForEach @(
        @{ Name = 'get weather' }, @{ Name = 'get.weather' }, @{ Name = ('x' * 65) }
    ) {
        { New-AzFoundryTool -Name $Name -Description 'd' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }

    It 'rejects a -Parameter that is not an object schema' {
        { New-AzFoundryTool -Name 'f' -Description 'd' -Parameter @{ city = 'string' } } |
            Should -Throw -ExpectedMessage '*JSON Schema object*'
    }

    It 'has a default table view with Name, Description and the argument names' {
        $table = New-AzFoundryTool -Name 'get_weather' -Description 'Weather' -Parameter $schema | Out-String
        $table | Should -Match 'Name\s+Description\s+Arguments'
        $table | Should -Match 'get_weather\s+Weather\s+city'
    }
}
