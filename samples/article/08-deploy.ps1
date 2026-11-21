<#
.SYNOPSIS
    Article step 8: deploy a model (text-embedding-3-small), wait until it answers, and call it.
.DESCRIPTION
    Needs 01-connect.ps1. Sets $deploymentUri for 09-cleanup.ps1. Needs the Cognitive Services Contributor
    role on the resource.
#>
$deploymentName = 'article-embedding'
$deploymentUri  = "${account}/deployments/${deploymentName}?api-version=$armApi"

$body = @{
    sku        = @{ name = 'GlobalStandard'; capacity = 5 }   # 5 requests and 5000 tokens per minute
    properties = @{ model = @{ format = 'OpenAI'; name = 'text-embedding-3-small'; version = '1' } }
} | ConvertTo-Json -Depth 5

$deployment = Invoke-RestMethod -Method Put -Uri $deploymentUri -Authentication Bearer -Token $armToken `
    -ContentType 'application/json' -Body $body
# From here on the deployment exists (and can be billed): if a step below fails, run 09-cleanup.ps1

# OpenAI models are ready at once; partner models (Mistral, Cohere...) are 'Creating' for about a minute
for ($poll = 1; $deployment.properties.provisioningState -notin 'Succeeded', 'Failed', 'Canceled'; $poll++) {
    if ($poll -gt 60) { throw "$deploymentName is still $($deployment.properties.provisioningState) after 5 min." }
    Start-Sleep -Seconds 5
    $deployment = Invoke-RestMethod -Uri $deploymentUri -Authentication Bearer -Token $armToken
}
if ($deployment.properties.provisioningState -ne 'Succeeded') { throw "Deployment $deploymentName failed." }

# 'Succeeded' on ARM does not mean ready: the data plane answers 404 for about 20 more seconds
$body = @{ model = $deploymentName; input = 'PowerShell loves REST' } | ConvertTo-Json
for ($attempt = 1; ; $attempt++) {
    try {
        $embedding = Invoke-RestMethod -Method Post -Uri "$endpoint/openai/v1/embeddings" `
            -Authentication Bearer -Token $apiKey -ContentType 'application/json' -Body $body
        break
    } catch {
        if ($attempt -ge 24 -or $_.Exception.Response.StatusCode -ne 'NotFound') { throw }
        Start-Sleep -Seconds 5
    }
}
"$deploymentName is ready: $($embedding.data[0].embedding.Count) dimensions"
