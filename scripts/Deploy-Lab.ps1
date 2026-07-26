#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the authenticated, fail-closed Lethal Trifecta research lab.

.PARAMETER ProjectName
    Lowercase resource prefix, 3-20 characters, without leading/trailing hyphens.

.PARAMETER Location
    Azure region name.

.PARAMETER SkipFunctionDeploy
    Skip code publication only when updating an already-published deployment.

.PARAMETER SkipSeed
    Skip the six synthetic Cosmos DB records.

.PARAMETER SkipTest
    Skip authenticated smoke tests.

.PARAMETER CleanupOnFailure
    After a failed deployment, invoke owned-resource cleanup for the exact tagged
    resource group. This is opt-in because cleanup is destructive.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{1,18}[a-z0-9])$')]
    [string]$ProjectName = 'trifecta-lab',

    [Parameter()]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location = 'eastus',

    [Parameter()]
    [switch]$SkipFunctionDeploy,

    [Parameter()]
    [switch]$SkipSeed,

    [Parameter()]
    [switch]$SkipTest,

    [Parameter()]
    [switch]$CleanupOnFailure
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LabRoot = Split-Path -Parent $ScriptDir
$OwnerMarker = 'lethal-trifecta-lab'
$deploymentStarted = $false
$config = @{}

function Invoke-AzRestPutJson {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Body,
        [switch]$PassThru
    )
    $bodyFile = New-TemporaryFile
    try {
        $json = $Body | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText(
            $bodyFile.FullName,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        $result = az rest --method PUT --uri $Uri `
            --headers 'Content-Type=application/json' `
            --body "@$($bodyFile.FullName)" `
            --output $(if ($PassThru) { 'json' } else { 'none' }) `
            --only-show-errors
        if ($PassThru) {
            if (-not $result) { throw "Azure returned no body for PUT $Uri" }
            return $result | ConvertFrom-Json -Depth 100
        }
    }
    finally {
        Remove-Item -LiteralPath $bodyFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-OrCreateFunctionKey {
    param(
        [Parameter(Mandatory)][string]$FunctionAppName,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )
    $keys = az functionapp keys list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --output json `
        --only-show-errors | ConvertFrom-Json
    $plainKey = $keys.functionKeys.'lab-client'
    if (-not $plainKey) {
        $plainKey = $keys.functionKeys.default
    }
    if (-not $plainKey) {
        $bytes = [byte[]]::new(32)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $plainKey = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        az functionapp keys set `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --key-name 'lab-client' `
            --key-value $plainKey `
            --output none `
            --only-show-errors
    }
    if (-not $plainKey) { throw 'Function App did not return or accept a host key.' }
    try {
        return ConvertTo-SecureString -String $plainKey -AsPlainText -Force
    }
    finally {
        Remove-Variable plainKey -ErrorAction SilentlyContinue
    }
}

function Publish-FunctionCode {
    param(
        [Parameter(Mandatory)][string]$FunctionAppName,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )
    $functionDir = Join-Path $LabRoot 'function'
    $coreTools = Get-Command func -ErrorAction SilentlyContinue
    if ($coreTools) {
        Push-Location $functionDir
        try {
            try {
                & $coreTools.Source azure functionapp publish $FunctionAppName --python
                if ($LASTEXITCODE -eq 0) { return }
            }
            catch {
                Write-Host '  Azure Functions Core Tools publish failed; trying authenticated zip deployment.' -ForegroundColor Yellow
            }
        }
        finally {
            Pop-Location
        }
    }

    $temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "trifecta-function-$([guid]::NewGuid())"
    $zipPath = "$temporaryRoot.zip"
    $runtimeFiles = @(
        'function_app.py', 'audit.py', 'policy_engine.py', 'session_tracker.py',
        'tool_registry.py', 'validation.py', 'tools.json', 'requirements.txt',
        'requirements.lock', 'host.json'
    )
    try {
        $null = New-Item -ItemType Directory -Path $temporaryRoot
        foreach ($fileName in $runtimeFiles) {
            $source = Join-Path $functionDir $fileName
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Required Function runtime file '$fileName' is missing."
            }
            Copy-Item -LiteralPath $source -Destination $temporaryRoot
        }
        Compress-Archive -Path (Join-Path $temporaryRoot '*') -DestinationPath $zipPath
        az functionapp deployment source config-zip `
            --resource-group $ResourceGroupName `
            --name $FunctionAppName `
            --src $zipPath `
            --build-remote true `
            --output none `
            --only-show-errors
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
            Get-ChildItem -LiteralPath $temporaryRoot -File | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $temporaryRoot -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "`n=== Lethal Trifecta Lab Deployment ===" -ForegroundColor Cyan
Write-Host "Project:  $ProjectName"
Write-Host "Location: $Location"

try {
    $azVersion = az version --output json --only-show-errors | ConvertFrom-Json
    $account = az account show --output json --only-show-errors | ConvertFrom-Json
    $deployerPrincipalId = az ad signed-in-user show --query id --output tsv --only-show-errors
    if (-not $azVersion -or -not $account.id -or -not $deployerPrincipalId) {
        throw 'Azure CLI login or signed-in user discovery failed.'
    }
    Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

    Write-Host "`nStep 1/7: Deploying owned Azure resources..." -ForegroundColor Cyan
    $deploymentStarted = $true
    $deploymentOutput = & (Join-Path $ScriptDir 'Deploy-Azure.ps1') `
        -ProjectName $ProjectName `
        -Location $Location `
        -DeployerPrincipalId $deployerPrincipalId

    foreach ($line in @($deploymentOutput | Where-Object { $_ -match '^[A-Z_]+=' })) {
        $parts = $line -split '=', 2
        $config[$parts[0]] = $parts[1]
    }
    $required = @(
        'RESOURCE_GROUP_NAME', 'FUNCTION_APP_NAME', 'FUNCTION_APP_URL',
        'FUNCTION_APP_PRINCIPAL_ID', 'COSMOS_ACCOUNT_NAME', 'COSMOS_ENDPOINT',
        'LOG_ANALYTICS_WORKSPACE_ID', 'DCR_ENDPOINT_URL', 'SUBSCRIPTION_ID'
    )
    foreach ($name in $required) {
        if (-not $config[$name]) { throw "Required deployment output '$name' is missing." }
    }

    $rgName = $config['RESOURCE_GROUP_NAME']
    $workspaceId = $config['LOG_ANALYTICS_WORKSPACE_ID']
    $workspaceName = ($workspaceId -split '/')[-1]
    $subscriptionId = $config['SUBSCRIPTION_ID']
    $dceId = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionEndpoints/$ProjectName-dce"
    $resourceTags = @{
        project = $ProjectName
        environment = 'lab'
        purpose = 'lethal-trifecta-demo'
        'nlzt-owner' = $OwnerMarker
    }

    Write-Host "`nStep 2/7: Creating audit table and Data Collection Rule..." -ForegroundColor Cyan
    $tableBody = @{
        properties = @{
            schema = @{
                name = 'TrifectaAudit_CL'
                columns = @(
                    @{ name='TimeGenerated'; type='datetime' },
                    @{ name='SessionId'; type='string' },
                    @{ name='ToolName'; type='string' },
                    @{ name='Condition'; type='string' },
                    @{ name='Decision'; type='string' },
                    @{ name='Reason'; type='string' },
                    @{ name='ConditionsBefore'; type='string' },
                    @{ name='ConditionsAfter'; type='string' },
                    @{ name='ConditionsMetCount'; type='int' }
                )
            }
        }
    }
    Invoke-AzRestPutJson `
        -Uri "https://management.azure.com$workspaceId/tables/TrifectaAudit_CL?api-version=2022-10-01" `
        -Body $tableBody

    $dcrBody = @{
        location = $Location
        tags = $resourceTags
        properties = @{
            dataCollectionEndpointId = $dceId
            streamDeclarations = @{
                'Custom-TrifectaAudit_CL' = @{
                    columns = $tableBody.properties.schema.columns
                }
            }
            dataFlows = @(@{
                streams = @('Custom-TrifectaAudit_CL')
                destinations = @($workspaceName)
                transformKql = 'source'
                outputStream = 'Custom-TrifectaAudit_CL'
            })
            destinations = @{
                logAnalytics = @(@{
                    workspaceResourceId = $workspaceId
                    name = $workspaceName
                })
            }
        }
    }
    $dcrUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionRules/$ProjectName-dcr?api-version=2022-06-01"
    $dcrResult = Invoke-AzRestPutJson -Uri $dcrUri -Body $dcrBody -PassThru
    $dcrRuleId = $dcrResult.properties.immutableId
    if ($dcrRuleId -notmatch '^dcr-[A-Za-z0-9-]{8,128}$') {
        throw 'Data Collection Rule returned an invalid immutable ID.'
    }

    Write-Host "`nStep 3/7: Granting DCR-scoped ingestion permission..." -ForegroundColor Cyan
    $dcrScope = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionRules/$ProjectName-dcr"
    & (Join-Path $ScriptDir 'Grant-Permissions.ps1') `
        -FunctionAppPrincipalId $config['FUNCTION_APP_PRINCIPAL_ID'] `
        -DcrScope $dcrScope

    Write-Host "`nStep 4/7: Configuring fail-closed runtime settings..." -ForegroundColor Cyan
    & (Join-Path $ScriptDir 'Configure-Function.ps1') `
        -FunctionAppName $config['FUNCTION_APP_NAME'] `
        -ResourceGroupName $rgName `
        -DcrEndpoint $config['DCR_ENDPOINT_URL'] `
        -DcrRuleId $dcrRuleId `
        -CosmosEndpoint $config['COSMOS_ENDPOINT']

    if (-not $SkipFunctionDeploy) {
        Write-Host "`nStep 5/7: Publishing Function App code..." -ForegroundColor Cyan
        Publish-FunctionCode `
            -FunctionAppName $config['FUNCTION_APP_NAME'] `
            -ResourceGroupName $rgName
    } else {
        Write-Host "`nStep 5/7: Code publication explicitly skipped." -ForegroundColor Yellow
    }

    if (-not $SkipSeed) {
        Write-Host "`nStep 6/7: Seeding synthetic Cosmos DB data..." -ForegroundColor Cyan
        & (Join-Path $ScriptDir 'Seed-Data.ps1') `
            -CosmosAccountName $config['COSMOS_ACCOUNT_NAME'] `
            -ResourceGroupName $rgName
    } else {
        Write-Host "`nStep 6/7: Synthetic data seed explicitly skipped." -ForegroundColor Yellow
    }

    if (-not $SkipTest) {
        Write-Host "`nStep 7/7: Running authenticated smoke tests..." -ForegroundColor Cyan
        $functionKey = Get-OrCreateFunctionKey `
            -FunctionAppName $config['FUNCTION_APP_NAME'] `
            -ResourceGroupName $rgName
        try {
            & (Join-Path $ScriptDir 'Test-Lab.ps1') `
                -FunctionAppUrl $config['FUNCTION_APP_URL'] `
                -FunctionKey $functionKey
        }
        finally {
            Remove-Variable functionKey -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "`nStep 7/7: Smoke tests explicitly skipped." -ForegroundColor Yellow
    }

    Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
    Write-Host "Function App URL: $($config['FUNCTION_APP_URL'])" -ForegroundColor Cyan
    Write-Host 'Gate, session, and registry routes require a Function host key.' -ForegroundColor Yellow
    Write-Host "Cleanup preview: ./scripts/Remove-Lab.ps1 -ProjectName '$ProjectName' -WhatIf"
}
catch {
    Write-Host "`nDeployment failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Azure does not automatically roll back every successfully provisioned resource.' -ForegroundColor Yellow
    if ($deploymentStarted) {
        Write-Host "Inspect or preview cleanup with: ./scripts/Remove-Lab.ps1 -ProjectName '$ProjectName' -WhatIf" -ForegroundColor Yellow
    }
    if ($CleanupOnFailure -and $deploymentStarted) {
        Write-Host 'CleanupOnFailure was requested; validating ownership before cleanup.' -ForegroundColor Yellow
        $cleanupSubscriptionId = if ($config['SUBSCRIPTION_ID']) { $config['SUBSCRIPTION_ID'] } else { $account.id }
        & (Join-Path $ScriptDir 'Remove-Lab.ps1') `
            -ProjectName $ProjectName `
            -SubscriptionId $cleanupSubscriptionId `
            -Confirm:$false
    }
    throw
}
