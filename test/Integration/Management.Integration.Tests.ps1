#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Management scenario on a real Foundry resource: connect through ARM, list the catalogue and the deployments,
    read the endpoint and keys, deploy a small embedding model, use it, and delete it.

    Creates deployments named 'pwshit-<purpose>-<timestamp>' and deletes them in AfterAll, whatever happened.
    Needs Connect-AzAccount and the Cognitive Services Contributor role on the resource.
    The optional partner test (AZURE_FOUNDRY_ASYNC_MODEL, e.g. Cohere-embed-v3-english) adds about two minutes.
#>

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'IntegrationHelpers.ps1')
    $setting = Get-ItSetting
    $skipPartner = -not ($setting.HasArm -and $setting.AsyncModel)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'IntegrationHelpers.ps1')
    Import-ItModule
    $setting = Get-ItSetting
    $target = Get-ItArmTarget
    $created = [System.Collections.Generic.List[string]]::new()
}

AfterAll {
    if ($created.Count -gt 0) {
        Remove-ItDeployment -Name $created
    }
    Disconnect-AzFoundry -ErrorAction SilentlyContinue
}

Describe 'Management plane' -Tag 'Integration' -Skip:(-not $setting.HasArm) {
    BeforeAll {
        Connect-AzFoundry @target
        $embedName = Get-ItDeploymentName -Purpose 'embed'
    }

    Context 'connection and discovery' {
        It 'connects through ARM with a key from listKeys' {
            $connection = Get-AzFoundryConnection
            $connection.AuthMode | Should -Be 'ApiKey'
            $connection.ResourceGroupName | Should -Be $setting.ResourceGroup
            $connection.AccountName | Should -Be $setting.Account
            $connection.Endpoint | Should -BeLike 'https://*'
        }

        It 'lists the catalogue, one version per model' {
            $models = @(Get-AzFoundryModel)
            $models.Count | Should -BeGreaterThan 10
            $models | Group-Object Format, Name | Where-Object Count -GT 1 | Should -BeNullOrEmpty
            $models | Where-Object IsDeprecated | Should -BeNullOrEmpty
        }

        It 'finds the embedding model with its capabilities' {
            $model = Get-AzFoundryModel -Name $setting.EmbeddingModel
            $model.Tasks | Should -Contain 'embeddings'
            $model.Skus | Should -Contain 'GlobalStandard'
        }

        It 'lists the existing deployments with their resource' {
            $deployments = @(Get-AzFoundryDeployment)
            $deployments.Name | Should -Contain $setting.ChatModel
            $deployments[0].ResourceGroupName | Should -Be $setting.ResourceGroup
            (Get-AzFoundryDeployment -Name $setting.ChatModel).ProvisioningState | Should -Be 'Succeeded'
        }

        It 'reads the endpoint and the keys as SecureString' {
            $endpoint = Get-AzFoundryEndpoint -IncludeKey
            $endpoint.Endpoint | Should -BeLike 'https://*.services.ai.azure.com'
            $endpoint.OpenAIEndpoint | Should -BeLike 'https://*.openai.azure.com'
            $endpoint.Endpoints.Count | Should -BeGreaterThan 2
            $endpoint.Key1 | Should -BeOfType [securestring]
            ($endpoint | Format-List * | Out-String) | Should -Not -Match ([regex]::Escape(
                    [System.Net.NetworkCredential]::new('', $endpoint.Key1).Password))
        }
    }

    Context 'deployment lifecycle (OpenAI model, synchronous)' {
        It 'creates nothing with -WhatIf' {
            New-AzFoundryDeployment -ModelName $setting.EmbeddingModel -Name $embedName -Capacity 1 -WhatIf
            Get-AzFoundryDeployment -Name $embedName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }

        It 'deploys the model and waits until it answers' {
            $created.Add($embedName)
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $output = New-AzFoundryDeployment -ModelName $setting.EmbeddingModel -Name $embedName -Capacity 1 `
                -Verbose 4>&1
            $stopwatch.Stop()
            $verbose = @($output | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }).Message
            $deployment = $output | Where-Object { $_.PSObject.TypeNames[0] -eq 'PwshAzureFoundry.Deployment' }

            $deployment.Name | Should -Be $embedName
            $deployment.ModelName | Should -Be $setting.EmbeddingModel
            $deployment.ProvisioningState | Should -Be 'Succeeded'
            $deployment.Capacity | Should -Be 1
            $verbose -join "`n" | Should -Match 'answers on the data plane'
            Write-Information ('Deployed and ready in {0:N0} s.' -f $stopwatch.Elapsed.TotalSeconds) `
                -InformationAction Continue
        }

        It 'embeds texts with the new deployment right away' {
            $result = @('one', 'two', 'three' | Invoke-AzFoundryEmbedding -Model $embedName -BatchSize 2)
            $result.Index | Should -Be @(0, 1, 2)
            $result[0].Dimensions | Should -BeGreaterThan 0
            $result[0].Vector | Should -BeOfType [float]
        }

        It 'honours -Dimensions' {
            (Invoke-AzFoundryEmbedding -Model $embedName -InputText 'short' -Dimensions 256).Dimensions | Should -Be 256
        }

        It 'refuses a second deployment with the same name' {
            { New-AzFoundryDeployment -ModelName $setting.EmbeddingModel -Name $embedName -Capacity 1 } |
                Should -Throw -ErrorId 'AzFoundryDeploymentExists,New-AzFoundryDeployment'
        }

        It 'deletes the deployment' {
            Remove-AzFoundryDeployment -Name $embedName -Confirm:$false
            $null = $created.Remove($embedName)
            Get-AzFoundryDeployment -Name $embedName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }
}

Describe 'Partner deployment (asynchronous)' -Tag 'Integration' -Skip:$skipPartner {
    BeforeAll {
        Connect-AzFoundry @target
        $partnerName = Get-ItDeploymentName -Purpose 'partner'
    }

    It 'deploys from a piped catalogue model and polls until Succeeded' {
        $created.Add($partnerName)
        $deployment = Get-AzFoundryModel -Name $setting.AsyncModel |
            New-AzFoundryDeployment -Name $partnerName -Capacity 1
        $deployment.ProvisioningState | Should -Be 'Succeeded'
        $deployment.Format | Should -Not -Be 'OpenAI'
    }

    It 'deletes it through the pipeline and waits' {
        Get-AzFoundryDeployment -Name $partnerName | Remove-AzFoundryDeployment -Confirm:$false
        $null = $created.Remove($partnerName)
        Get-AzFoundryDeployment -Name $partnerName -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
