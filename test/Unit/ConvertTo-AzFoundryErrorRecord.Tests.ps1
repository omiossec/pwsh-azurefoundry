#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-TestModule

    function ConvertFrom-TestError {
        param([int]$Status, [string]$Content)
        InModuleScope PwshAzureFoundry -Parameters @{ S = $Status; C = $Content } {
            param($S, $C)
            ConvertFrom-AzFoundryErrorResponse -StatusCode $S -Content $C
        }
    }

    function ConvertTo-TestErrorRecord {
        param([psobject]$Response, [string[]]$Secret)
        InModuleScope PwshAzureFoundry -Parameters @{ R = $Response; S = $Secret } {
            param($R, $S)
            ConvertTo-AzFoundryErrorRecord -Response $R -Method 'POST' -Secret $S `
                -Uri 'https://lab.openai.azure.com/openai/v1/chat/completions'
        }
    }
}

Describe 'ConvertFrom-AzFoundryErrorResponse' {
    It 'normalises <Fixture>' -ForEach @(
        @{ Fixture = 'error-401.json'; Status = 401; Code = '401'; Message = 'Access denied*' }
        @{ Fixture = 'error-route-not-found-404.json'; Status = 404; Code = '404'; Message = 'Resource not found' }
        @{ Fixture = 'error-deployment-not-found.json'; Status = 404; Code = 'DeploymentNotFound'; Message = 'The API deployment*' }
        @{ Fixture = 'error-decision-deployment-not-found.json'; Status = 404; Code = 'DeploymentNotFound'; Message = '*decision-1 does not exist*' }
        @{ Fixture = 'error-unsupported-value-400.json'; Status = 400; Code = 'unsupported_request_value'; Message = '*temperature*' }
        @{ Fixture = 'error-unrecognized-argument-400.json'; Status = 400; Code = 'unrecognized_request_argument'; Message = '*not_a_real_param' }
        @{ Fixture = 'error-decision-validation-422.json'; Status = 422; Code = 'ValidationError'; Message = 'body.questions.q: Input tag*' }
        @{ Fixture = 'error-deployment-creating-400.json'; Status = 400; Code = 'DeploymentCreating'; Message = '*being created*' }
        @{ Fixture = 'synthetic-error-429.json'; Status = 429; Code = '429'; Message = '*retry after 6 seconds*' }
        @{ Fixture = 'synthetic-error-content-filter-400.json'; Status = 400; Code = 'content_filter'; Message = '*content management policy*' }
    ) {
        $result = ConvertFrom-TestError -Status $Status -Content (Get-TestFixture $Fixture)
        $result.Status | Should -Be $Status
        $result.Code | Should -BeExactly $Code
        $result.Message | Should -BeLike $Message
    }

    It 'keeps details, OpenAI type and inner error code' {
        (ConvertFrom-TestError 400 (Get-TestFixture 'error-unsupported-value-400.json')).Details | Should -Match 'temperature'
        (ConvertFrom-TestError 404 (Get-TestFixture 'error-deployment-not-found.json')).Details |
            Should -Be 'invalid_request_error'
        (ConvertFrom-TestError 400 (Get-TestFixture 'synthetic-error-content-filter-400.json')).InnerCode |
            Should -Be 'ResponsibleAIPolicyViolation'
        (ConvertFrom-TestError 422 (Get-TestFixture 'error-decision-validation-422.json')).Details[0].type |
            Should -Be 'union_tag_invalid'
    }

    It 'handles an ARM error body' {
        $body = '{"error":{"code":"InsufficientQuota","message":"Not enough quota.","details":[{"code":"x"}]}}'
        $result = ConvertFrom-TestError 400 $body
        $result.Code | Should -Be 'InsufficientQuota'
        $result.Details[0].code | Should -Be 'x'
    }

    It 'keeps a non-JSON body as the message and falls back to the status code' {
        $result = ConvertFrom-TestError 502 '<html>Bad Gateway</html>'
        $result.Code | Should -Be '502'
        $result.Message | Should -Be '<html>Bad Gateway</html>'
    }

    It 'truncates a long non-JSON body' {
        (ConvertFrom-TestError 500 ('x' * 2000)).Message.Length | Should -Be 503
    }

    It 'handles an empty body' {
        $result = ConvertFrom-TestError 503 ''
        $result.Code | Should -Be '503'
        $result.Message | Should -Match 'no error details'
    }
}

Describe 'ConvertTo-AzFoundryErrorRecord' {
    It 'maps <Fixture> (HTTP <Status>) to <Category>' -ForEach @(
        @{ Fixture = 'error-401.json'; Status = 401; Category = 'AuthenticationError'; ErrorId = 'AzFoundry.Http401'; Hint = 'Connect-AzAccount' }
        @{ Fixture = 'error-route-not-found-404.json'; Status = 404; Category = 'ObjectNotFound'; ErrorId = 'AzFoundry.Http404'; Hint = 'Get-AzFoundryDeployment' }
        @{ Fixture = 'error-deployment-not-found.json'; Status = 404; Category = 'ObjectNotFound'; ErrorId = 'AzFoundry.DeploymentNotFound'; Hint = 'Get-AzFoundryDeployment' }
        @{ Fixture = 'error-decision-deployment-not-found.json'; Status = 404; Category = 'ObjectNotFound'; ErrorId = 'AzFoundry.DeploymentNotFound'; Hint = '20 seconds' }
        @{ Fixture = 'error-unsupported-value-400.json'; Status = 400; Category = 'InvalidArgument'; ErrorId = 'AzFoundry.unsupported_request_value'; Hint = $null }
        @{ Fixture = 'error-unrecognized-argument-400.json'; Status = 400; Category = 'InvalidArgument'; ErrorId = 'AzFoundry.unrecognized_request_argument'; Hint = $null }
        @{ Fixture = 'error-decision-validation-422.json'; Status = 422; Category = 'InvalidArgument'; ErrorId = 'AzFoundry.ValidationError'; Hint = $null }
        @{ Fixture = 'error-deployment-creating-400.json'; Status = 400; Category = 'ResourceBusy'; ErrorId = 'AzFoundry.DeploymentCreating'; Hint = 'Succeeded' }
        @{ Fixture = 'synthetic-error-429.json'; Status = 429; Category = 'LimitsExceeded'; ErrorId = 'AzFoundry.Http429'; Hint = 'capacity' }
        @{ Fixture = 'synthetic-error-content-filter-400.json'; Status = 400; Category = 'SecurityError'; ErrorId = 'AzFoundry.content_filter'; Hint = 'content filter' }
    ) {
        $response = New-TestResponse -StatusCode $Status -Content (Get-TestFixture $Fixture)
        $record = ConvertTo-TestErrorRecord -Response $response

        $record.CategoryInfo.Category | Should -Be $Category
        $record.FullyQualifiedErrorId | Should -Be $ErrorId
        $record.Exception | Should -BeOfType [System.Net.Http.HttpRequestException]
        [int]$record.Exception.StatusCode | Should -Be $Status
        $record.Exception.Data['AzFoundryError'].Status | Should -Be $Status
        $record.Exception.Message | Should -Match "^POST https://lab.openai.azure.com/openai/v1/chat/completions failed with HTTP $Status"
        $record.TargetObject | Should -Be 'https://lab.openai.azure.com/openai/v1/chat/completions'
        if ($Hint) {
            $record.ErrorDetails.RecommendedAction | Should -Match $Hint
        }
    }

    It 'maps <Status> to <Category>' -ForEach @(
        @{ Status = 403; Category = 'PermissionDenied' }
        @{ Status = 409; Category = 'ResourceExists' }
        @{ Status = 500; Category = 'ResourceUnavailable' }
        @{ Status = 503; Category = 'ResourceUnavailable' }
        @{ Status = 418; Category = 'NotSpecified' }
    ) {
        $record = ConvertTo-TestErrorRecord -Response (New-TestResponse -StatusCode $Status -Content '{"error":{"code":"X","message":"m"}}')
        $record.CategoryInfo.Category | Should -Be $Category
    }

    It 'masks a secret echoed by the service' {
        $response = New-TestResponse -StatusCode 401 -Content '{"error":{"code":"401","message":"Bad key abcdef0123456789xyz"}}'
        $record = ConvertTo-TestErrorRecord -Response $response -Secret 'abcdef0123456789xyz'
        $record.Exception.Message | Should -Not -Match 'abcdef0123456789xyz'
        $record.Exception.Data['AzFoundryError'].Message | Should -Not -Match 'abcdef0123456789xyz'
        $record.ErrorDetails.Message | Should -Not -Match 'abcdef0123456789xyz'
    }
}
