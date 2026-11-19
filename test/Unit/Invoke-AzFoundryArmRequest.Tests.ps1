#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    $script:accountPath = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/' +
        'providers/Microsoft.CognitiveServices/accounts/test-foundry'
    $script:deploymentPath = "$script:accountPath/deployments/spike-cohere"
    $script:operationUri = 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/' +
        'providers/Microsoft.CognitiveServices/locations/swedencentral/operationResults/' +
        '00000000-0000-0000-0000-000000000000?api-version=2025-06-01'

    function Invoke-ArmTest {
        param([hashtable]$Parameters)
        InModuleScope PwshAzureFoundry -Parameters @{ P = $Parameters } {
            param($P)
            Invoke-AzFoundryArmRequest @P
        }
    }

    # Send-AzFoundryHttpRequest returns the queued responses in order.
    function Set-ArmResponse {
        param([object[]]$Response)
        $script:armQueue = [System.Collections.Generic.Queue[object]]::new()
        foreach ($item in $Response) { $script:armQueue.Enqueue($item) }
    }
}

Describe 'Invoke-AzFoundryArmRequest' {
    BeforeEach {
        Mock -ModuleName PwshAzureFoundry Start-Sleep {}
        Mock -ModuleName PwshAzureFoundry Get-AzFoundryAccessToken {
            [pscustomobject]@{
                Token     = ConvertTo-SecureString 'arm-token-0123456789' -AsPlainText -Force
                ExpiresOn = [datetimeoffset]::UtcNow.AddHours(1)
            }
        }
        Mock -ModuleName PwshAzureFoundry Send-AzFoundryHttpRequest {
            if ($script:armQueue.Count -eq 0) { throw 'No more queued ARM responses.' }
            $script:armQueue.Dequeue()
        }
    }

    Context 'GET' {
        It 'calls the ARM base URI with the module api-version and an ARM token' {
            Set-ArmResponse @(New-TestResponse -Content (Get-TestFixture 'arm-account.json'))
            $result = Invoke-ArmTest @{ Path = $script:accountPath }
            $result.name | Should -Not -BeNullOrEmpty
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -eq "https://management.azure.com$($script:accountPath)?api-version=2025-06-01" -and
                $Method -eq 'GET' -and $Headers['Authorization'] -eq 'Bearer arm-token-0123456789'
            }
            Should -Invoke Get-AzFoundryAccessToken -ModuleName PwshAzureFoundry -ParameterFilter {
                $ResourceUrl -eq 'https://management.azure.com/'
            }
        }

        It 'uses -ApiVersion when given' {
            Set-ArmResponse @(New-TestResponse -Content '{}')
            Invoke-ArmTest @{ Path = $script:accountPath; ApiVersion = '2026-03-01' } | Out-Null
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -ParameterFilter {
                $Uri.Query -eq '?api-version=2026-03-01'
            }
        }

        It 'outputs each item of a list' {
            Set-ArmResponse @(New-TestResponse -Content (Get-TestFixture 'arm-deployments.json'))
            $expected = (Get-TestFixture 'arm-deployments.json' | ConvertFrom-Json).value.Count
            $result = @(Invoke-ArmTest @{ Path = "$script:accountPath/deployments" })
            $result.Count | Should -Be $expected
            $result[0].name | Should -Be 'Mistral-Large-3'
        }

        It 'follows nextLink' {
            $next = "https://management.azure.com$($script:accountPath)/models?api-version=2025-06-01&`$skipToken=abc"
            Set-ArmResponse @(
                New-TestResponse -Content (@{ value = @(@{ name = 'a' }); nextLink = $next } | ConvertTo-Json)
                New-TestResponse -Content (@{ value = @(@{ name = 'b' }, @{ name = 'c' }) } | ConvertTo-Json)
            )
            $result = @(Invoke-ArmTest @{ Path = "$script:accountPath/models" })
            $result.name | Should -Be @('a', 'b', 'c')
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -eq ([uri]$next).AbsoluteUri
            }
        }

        It 'outputs nothing for an empty list' {
            Set-ArmResponse @(New-TestResponse -Content '{"value":[]}')
            @(Invoke-ArmTest @{ Path = "$script:accountPath/deployments" }).Count | Should -Be 0
        }

        It 'refuses a nextLink on another host without sending the token' {
            Set-ArmResponse @(
                New-TestResponse -Content '{"value":[{"name":"a"}],"nextLink":"https://evil.example.com/steal"}'
            )
            $err = { Invoke-ArmTest @{ Path = "$script:accountPath/models" } } |
                Should -Throw -ErrorId 'AzFoundryArmUnexpectedHost,Invoke-AzFoundryArmRequest' -PassThru
            $err.CategoryInfo.Category | Should -Be 'SecurityError'
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
        }

        It 'maps an ARM error and masks the token' {
            Set-ArmResponse @(New-TestResponse -StatusCode 404 -Content (
                    '{"error":{"code":"ResourceNotFound","message":"Not found (token arm-token-0123456789)."}}'))
            $err = { Invoke-ArmTest @{ Path = $script:accountPath } } |
                Should -Throw -ErrorId 'AzFoundry.ResourceNotFound,Invoke-AzFoundryArmRequest' -PassThru
            $err.CategoryInfo.Category | Should -Be 'ObjectNotFound'
            $err.Exception.Message | Should -Not -Match 'arm-token-0123456789'
        }
    }

    Context 'synchronous PUT, POST and DELETE' {
        It 'returns the body of a synchronous PUT (OpenAI model) without polling' {
            Set-ArmResponse @(Get-TestFixtureResponse 'arm-deployment-put-sync')
            $body = [ordered]@{ sku = [ordered]@{ name = 'GlobalStandard'; capacity = 1 } }
            $result = Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'PUT'; Body = $body }
            $result.properties.provisioningState | Should -Be 'Succeeded'
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PUT' -and $Body -eq '{"sku":{"name":"GlobalStandard","capacity":1}}'
            }
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 0 -Exactly
        }

        It 'returns the keys of a POST listKeys' {
            Set-ArmResponse @(New-TestResponse -Content (Get-TestFixture 'arm-listKeys.json'))
            $result = Invoke-ArmTest @{ Path = "$script:accountPath/listKeys"; Method = 'POST' }
            $result.PSObject.Properties.Name | Should -Contain 'key1'
        }

        It 'outputs nothing for a synchronous DELETE' {
            Set-ArmResponse @(Get-TestFixtureResponse 'arm-deployment-delete-sync')
            @(Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'DELETE' }).Count | Should -Be 0
        }
    }

    Context 'asynchronous operations' {
        It 'polls a PUT until Succeeded, then returns the resource' {
            $final = (Get-TestFixture 'arm-deployment-put-async.json') -replace '"Creating"', '"Succeeded"'
            Set-ArmResponse @(
                Get-TestFixtureResponse 'arm-deployment-put-async'
                Get-TestFixtureResponse 'arm-operation-running'
                Get-TestFixtureResponse 'arm-operation-succeeded'
                New-TestResponse -Content $final
            )
            $result = Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'PUT'; Body = @{} }

            $result.properties.provisioningState | Should -Be 'Succeeded'
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 4 -Exactly
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 2 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Uri.AbsoluteUri -eq $script:operationUri
            }
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'GET' -and $Uri.AbsolutePath -eq $script:deploymentPath
            }
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 2 -Exactly -ParameterFilter {
                $Milliseconds -eq 5000
            }
        }

        It 'returns the first response with -NoWait' {
            Set-ArmResponse @(Get-TestFixtureResponse 'arm-deployment-put-async')
            $result = Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'PUT'; Body = @{}; NoWait = $true }
            $result.properties.provisioningState | Should -Be 'Creating'
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
        }

        It 'polls a DELETE (202 + Location) and outputs nothing' {
            Set-ArmResponse @(
                Get-TestFixtureResponse 'arm-deployment-delete-async'
                Get-TestFixtureResponse 'arm-operation-succeeded'
            )
            @(Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'DELETE' }).Count | Should -Be 0
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 2 -Exactly
        }

        It 'follows Location when there is no Azure-AsyncOperation header, keeps polling on 202 and honours Retry-After' {
            $location = 'https://management.azure.com/subscriptions/x/operationResults/1?api-version=2025-06-01&sig=S'
            $location2 = 'https://management.azure.com/subscriptions/x/operationResults/2?api-version=2025-06-01&sig=S'
            Set-ArmResponse @(
                New-TestResponse -StatusCode 202 -Headers @{ Location = $location; 'Retry-After' = '2' }
                New-TestResponse -StatusCode 202 -Headers @{ Location = $location2; 'Retry-After' = '3' }
                New-TestResponse -StatusCode 200 -Content ''
            )
            @(Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'DELETE' }).Count | Should -Be 0
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -eq $location
            }
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter {
                $Uri.AbsoluteUri -eq $location2
            }
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 2000 }
            Should -Invoke Start-Sleep -ModuleName PwshAzureFoundry -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 3000 }
        }

        It 'fails when the operation fails, with the service error' {
            Set-ArmResponse @(
                Get-TestFixtureResponse 'arm-deployment-put-async'
                New-TestResponse -Content '{"status":"Failed","error":{"code":"QuotaExceeded","message":"No quota left."}}'
            )
            $err = { Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'PUT'; Body = @{} } } |
                Should -Throw -ErrorId 'AzFoundryArmOperationFailed,Invoke-AzFoundryArmRequest' -PassThru
            $err.Exception.Message | Should -Match 'Failed \(QuotaExceeded: No quota left\.\)'
        }

        It 'stops polling after -PollTimeoutSec' {
            Set-ArmResponse @(Get-TestFixtureResponse 'arm-deployment-put-async')
            $err = { Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'PUT'; Body = @{}; PollTimeoutSec = 1 } } |
                Should -Throw -ErrorId 'AzFoundryArmOperationTimeout,Invoke-AzFoundryArmRequest' -PassThru
            $err.CategoryInfo.Category | Should -Be 'OperationTimeout'
        }

        It 'refuses a polling URL on another host' {
            Set-ArmResponse @(
                New-TestResponse -StatusCode 202 -Headers @{ Location = 'https://evil.example.com/op' }
            )
            { Invoke-ArmTest @{ Path = $script:deploymentPath; Method = 'DELETE' } } |
                Should -Throw -ErrorId 'AzFoundryArmUnexpectedHost,Invoke-AzFoundryArmRequest'
            Should -Invoke Send-AzFoundryHttpRequest -ModuleName PwshAzureFoundry -Times 1 -Exactly
        }
    }
}
