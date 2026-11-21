#Requires -Version 7.4

function Invoke-AzFoundryDecision {
    <#
    .SYNOPSIS
        Asks typed questions about a state to a decision model deployed on an Azure AI Foundry resource.
    .DESCRIPTION
        Calls POST /providers/microsoft/v1/systemone on the resource. Decision models (Microsoft-Decision) do not
        generate text: they answer typed questions about a state.

        Question types:
          - -Predicate (noul): a yes/no question; the model returns the probability that it is true.
          - -Choice: pick one of several labelled options.
          - -Score: place the state on an ordered scale.
          - -Question: raw question definitions, sent as-is.
        Questions are sent in this order: Predicate, Choice, Score, Question. Use [ordered]@{} to control the
        order within a parameter. Question ids must be unique across all the parameters.

        Output: one PwshAzureFoundry.DecisionAnswer per question (Question, Type, Answer, Value, Confidence,
        Probabilities, Model, InputTokens, OutputTokens, RateLimit, State), in the order of the questions.
        Each state piped in is one request; the State property tells the answers apart.
    .PARAMETER Model
        Decision deployment name, for example Decision-1.1.
    .PARAMETER State
        The data the questions are about: a string, or any object (hashtable, PSCustomObject) sent as JSON.
        Accepts pipeline input (one request per state).
    .PARAMETER Predicate
        Predicate questions: question id -> instructions, e.g. @{ urgent = 'Does this message convey urgency?' }.
    .PARAMETER Choice
        Choice questions: question id -> dictionary of option key -> label (at least two),
        e.g. @{ team = [ordered]@{ sales = 'Sales'; support = 'Support' } }.
    .PARAMETER Score
        Score questions: question id -> ordered list of levels, lowest first (at least two),
        e.g. @{ priority = 'low', 'medium', 'high' }.
    .PARAMETER Question
        Raw question definitions sent as-is: question id -> @{ type = ...; instructions = ...; criteria = ... }.
    .PARAMETER Threshold
        Cut-off for the Answer of a predicate: Answer is $true when the probability is at least this value
        (default 0.5).
    .PARAMETER Raw
        Output the response of the service as parsed JSON instead of DecisionAnswer objects.
    .PARAMETER TimeoutSec
        Request timeout in seconds (default 120).
    .PARAMETER Endpoint
        Endpoint of the resource, overriding the session connection (needs -ApiKey or -UseEntraId, unless it is
        the resource of the session).
    .PARAMETER ApiKey
        API key (SecureString) overriding the session authentication.
    .PARAMETER UseEntraId
        Use an Entra ID token (Az.Accounts and Connect-AzAccount) instead of a key.
    .PARAMETER AllowCustomEndpoint
        Accept an -Endpoint host outside Azure (*.services.ai.azure.com, *.openai.azure.com,
        *.cognitiveservices.azure.com), such as a custom domain or a gateway. The key or token is sent to it;
        a warning is shown once per host.
    .EXAMPLE
        Invoke-AzFoundryDecision -Model 'Decision-1.1' `
            -State 'The payment integration still fails. Please help today.' `
            -Predicate @{ urgent = 'Does this message convey urgency?' }

        Returns one answer: urgent = True, with its probability.
    .EXAMPLE
        $ticket = @{ subject = 'Charged twice'; body = 'My invoice is wrong, I was charged twice this month.' }
        Invoke-AzFoundryDecision -Model 'Decision-1.1' -State $ticket `
            -Predicate @{ billing = 'Is this ticket about billing?' } `
            -Choice @{ team = [ordered]@{ sales = 'Sales'; support = 'Support'; finance = 'Finance' } } `
            -Score @{ priority = 'low', 'medium', 'high' }

        Returns three answers: billing (True/False), team (finance) and priority (low, medium or high).
    .EXAMPLE
        $tickets | Invoke-AzFoundryDecision -Model 'Decision-1.1' -Predicate @{ urgent = 'Is it urgent?' } |
            Where-Object Answer | Select-Object -ExpandProperty State

        Keeps the urgent tickets.
    .NOTES
        The connection comes from, in this order: -Endpoint/-ApiKey/-UseEntraId, the connection set by
        Connect-AzFoundry, then the AZURE_FOUNDRY_ENDPOINT and AZURE_FOUNDRY_API_KEY environment variables.
    .LINK
        Invoke-AzFoundryChat
    .LINK
        Connect-AzFoundry
    #>
    [CmdletBinding()]
    [OutputType('PwshAzureFoundry.DecisionAnswer')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Model,

        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateNotNull()]
        [object]$State,

        [System.Collections.IDictionary]$Predicate,

        [System.Collections.IDictionary]$Choice,

        [System.Collections.IDictionary]$Score,

        [System.Collections.IDictionary]$Question,

        [ValidateRange(0.0, 1.0)]
        [double]$Threshold = 0.5,

        [switch]$Raw,

        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = $script:AzFoundryDefaultTimeoutSec,

        [ValidateNotNullOrEmpty()]
        [string]$Endpoint,

        [securestring]$ApiKey,

        [switch]$UseEntraId,

        [switch]$AllowCustomEndpoint
    )

    begin {
        try {
            $questions = ConvertTo-AzFoundryDecisionQuestion -Predicate $Predicate -Choice $Choice -Score $Score `
                -Question $Question
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }

        $connectionParameters = @{}
        foreach ($name in 'Endpoint', 'ApiKey', 'UseEntraId', 'AllowCustomEndpoint') {
            if ($PSBoundParameters.ContainsKey($name)) {
                $connectionParameters[$name] = $PSBoundParameters[$name]
            }
        }
        try {
            $connection = Resolve-AzFoundryConnection @connectionParameters
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }

    process {
        # A piped string arrives wrapped in a PSObject; unwrap it so it is sent as a JSON string.
        $value = if ($State -is [psobject] -and $State.BaseObject -is [string]) { $State.BaseObject } else { $State }
        $body = [ordered]@{
            model     = $Model
            state     = $value
            questions = $questions
        }
        Write-Verbose ('Decision with {0}: {1} question(s).' -f $Model, $questions.Count)
        try {
            $response = Invoke-AzFoundryRequest -Connection $connection -Path '/providers/microsoft/v1/systemone' `
                -Body $body -TimeoutSec $TimeoutSec -IncludeResponseInfo
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
        if ($response.Content.usage) {
            Write-Verbose ('Tokens: {0} in, {1} out.' -f $response.Content.usage.input_tokens,
                $response.Content.usage.output_tokens)
        }
        if ($Raw) {
            return $response.Content
        }
        ConvertTo-AzFoundryDecision -Response $response.Content -Questions $questions -Threshold $Threshold `
            -Headers $response.Headers -State $value
    }
}
