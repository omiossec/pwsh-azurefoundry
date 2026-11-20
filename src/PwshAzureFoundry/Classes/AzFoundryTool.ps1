#Requires -Version 7.4

# Function tool definition for Invoke-AzFoundryChat -Tool (spec sections 5.2 and 6).
# ToHashtable() returns the wire shape { type = 'function', function = { name, description, parameters } }.
class AzFoundryTool {
    [ValidatePattern('^[a-zA-Z0-9_-]{1,64}$')]
    [string] $Name

    [string] $Description

    # JSON Schema of the arguments (type = 'object', properties, required). $null for a tool with no arguments.
    [System.Collections.IDictionary] $Parameters

    AzFoundryTool() {}

    AzFoundryTool([string]$name, [string]$description, [System.Collections.IDictionary]$parameters) {
        $this.Name        = $name
        $this.Description = $description
        $this.Parameters  = $parameters
    }

    [System.Collections.Specialized.OrderedDictionary] ToHashtable() {
        $function = [ordered]@{ name = $this.Name }
        if (-not [string]::IsNullOrEmpty($this.Description)) {
            $function['description'] = $this.Description
        }
        if ($null -ne $this.Parameters) {
            $function['parameters'] = $this.Parameters
        }
        return [ordered]@{
            type     = 'function'
            function = $function
        }
    }

    [string] ToString() {
        return $this.Name
    }
}
