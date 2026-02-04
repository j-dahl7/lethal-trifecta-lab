#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Lethal Trifecta lab infrastructure.

.DESCRIPTION
    Main orchestrator script that deploys:
    1. Azure resources via Bicep (Resource Group, Cosmos DB, Key Vault, Function App, Log Analytics, DCE)
    2. TrifectaAudit_CL custom table and Data Collection Rule (DCR)
    3. Monitoring Metrics Publisher RBAC role on DCR for Function App identity
    4. Function App configuration (DCR endpoint, Cosmos DB settings)
    5. Function App code deployment
    6. Cosmos DB seed data (fake employee records)
    7. Smoke test

.PARAMETER ProjectName
    Project name for resource naming. Lowercase alphanumeric with hyphens, 3-20 chars.

.PARAMETER Location
    Azure region for deployment. Default: eastus

.PARAMETER SkipFunctionDeploy
    Skip deploying Function App code (useful for re-running after code changes)

.PARAMETER SkipSeed
    Skip seeding Cosmos DB with employee records

.PARAMETER SkipTest
    Skip running the smoke test after deployment

.EXAMPLE
    ./Deploy-Lab.ps1
    Deploys with default settings (trifecta-lab in eastus)

.EXAMPLE
    ./Deploy-Lab.ps1 -ProjectName "my-trifecta" -Location "westus2"
    Deploys with custom project name and region
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[a-z0-9-]+$')]
    [ValidateLength(3, 20)]
    [string]$ProjectName = 'trifecta-lab',

    [Parameter()]
    [string]$Location = 'eastus',

    [Parameter()]
    [switch]$SkipFunctionDeploy,

    [Parameter()]
    [switch]$SkipSeed,

    [Parameter()]
    [switch]$SkipTest
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LabRoot = Split-Path -Parent $ScriptDir

Write-Host "`n=== Lethal Trifecta Lab Deployment ===" -ForegroundColor Cyan
Write-Host "Project:  $ProjectName"
Write-Host "Location: $Location"
Write-Host ""

# Verify prerequisites
Write-Host "Checking prerequisites..." -ForegroundColor Yellow
$azVersion = az version --output json 2>$null | ConvertFrom-Json
if (-not $azVersion) {
    throw "Azure CLI not found. Install from https://aka.ms/installazurecli"
}
Write-Host "  Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green

# Check logged in
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    throw "Not logged in to Azure. Run 'az login' first."
}
Write-Host "  Subscription: $($account.name)" -ForegroundColor Green
Write-Host "  Tenant: $($account.tenantId)" -ForegroundColor Green

# Get deployer principal ID
$deployerPrincipalId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $deployerPrincipalId) {
    throw "Could not get signed-in user. Ensure you're logged in with 'az login'."
}
Write-Host "  Deployer: $deployerPrincipalId" -ForegroundColor Green

Write-Host ""

# Step 1: Deploy Azure Resources
Write-Host "Step 1/7: Deploying Azure resources (Bicep)..." -ForegroundColor Cyan
$deploymentOutput = & "$ScriptDir/Deploy-Azure.ps1" `
    -ProjectName $ProjectName `
    -Location $Location `
    -DeployerPrincipalId $deployerPrincipalId

if ($LASTEXITCODE -ne 0) {
    throw "Azure deployment failed"
}

# Parse deployment outputs
$outputLines = $deploymentOutput | Where-Object { $_ -match '^[A-Z_]+=' }
$config = @{}
foreach ($line in $outputLines) {
    $parts = $line -split '=', 2
    if ($parts.Count -eq 2) {
        $config[$parts[0]] = $parts[1]
    }
}

Write-Host "  Resource Group: $($config['RESOURCE_GROUP_NAME'])" -ForegroundColor Green
Write-Host "  Function App:   $($config['FUNCTION_APP_NAME'])" -ForegroundColor Green
Write-Host "  Cosmos DB:      $($config['COSMOS_ACCOUNT_NAME'])" -ForegroundColor Green
Write-Host ""

# Step 2: Create Custom Table and Data Collection Rule
Write-Host "Step 2/7: Creating TrifectaAudit_CL table and Data Collection Rule..." -ForegroundColor Cyan

$workspaceId = $config['LOG_ANALYTICS_WORKSPACE_ID']
$workspaceName = ($workspaceId -split '/')[-1]
$rgName = $config['RESOURCE_GROUP_NAME']
$dceId = "/subscriptions/$($config['SUBSCRIPTION_ID'])/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionEndpoints/$ProjectName-dce"

# Create custom table
Write-Host "  Creating TrifectaAudit_CL custom table..." -ForegroundColor Cyan
$tableBody = @{
    properties = @{
        schema = @{
            name = "TrifectaAudit_CL"
            columns = @(
                @{ name = "TimeGenerated"; type = "datetime" }
                @{ name = "SessionId"; type = "string" }
                @{ name = "ToolName"; type = "string" }
                @{ name = "Condition"; type = "string" }
                @{ name = "Decision"; type = "string" }
                @{ name = "Reason"; type = "string" }
                @{ name = "ConditionsBefore"; type = "string" }
                @{ name = "ConditionsAfter"; type = "string" }
                @{ name = "ConditionsMetCount"; type = "int" }
            )
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

az rest --method PUT `
    --uri "https://management.azure.com${workspaceId}/tables/TrifectaAudit_CL?api-version=2022-10-01" `
    --headers "Content-Type=application/json" `
    --body $tableBody `
    --output none 2>$null

Write-Host "    TrifectaAudit_CL table created" -ForegroundColor Green

# Create Data Collection Rule
Write-Host "  Creating Data Collection Rule..." -ForegroundColor Cyan
$dcrBody = @{
    location = $Location
    properties = @{
        dataCollectionEndpointId = $dceId
        streamDeclarations = @{
            "Custom-TrifectaAudit_CL" = @{
                columns = @(
                    @{ name = "TimeGenerated"; type = "datetime" }
                    @{ name = "SessionId"; type = "string" }
                    @{ name = "ToolName"; type = "string" }
                    @{ name = "Condition"; type = "string" }
                    @{ name = "Decision"; type = "string" }
                    @{ name = "Reason"; type = "string" }
                    @{ name = "ConditionsBefore"; type = "string" }
                    @{ name = "ConditionsAfter"; type = "string" }
                    @{ name = "ConditionsMetCount"; type = "int" }
                )
            }
        }
        dataFlows = @(
            @{
                streams = @("Custom-TrifectaAudit_CL")
                destinations = @("$workspaceName")
                transformKql = "source"
                outputStream = "Custom-TrifectaAudit_CL"
            }
        )
        destinations = @{
            logAnalytics = @(
                @{
                    workspaceResourceId = $workspaceId
                    name = $workspaceName
                }
            )
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

$dcrResult = az rest --method PUT `
    --uri "https://management.azure.com/subscriptions/$($config['SUBSCRIPTION_ID'])/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionRules/$ProjectName-dcr?api-version=2022-06-01" `
    --headers "Content-Type=application/json" `
    --body $dcrBody `
    --output json 2>$null | ConvertFrom-Json

$dcrRuleId = $dcrResult.properties.immutableId
$config['DCR_RULE_ID'] = $dcrRuleId
Write-Host "    DCR created with immutableId: $dcrRuleId" -ForegroundColor Green
Write-Host ""

# Step 3: Grant Permissions
Write-Host "Step 3/7: Granting Monitoring Metrics Publisher on DCR..." -ForegroundColor Cyan
$dcrScope = "/subscriptions/$($config['SUBSCRIPTION_ID'])/resourceGroups/$rgName/providers/Microsoft.Insights/dataCollectionRules/$ProjectName-dcr"
& "$ScriptDir/Grant-Permissions.ps1" `
    -FunctionAppPrincipalId $config['FUNCTION_APP_PRINCIPAL_ID'] `
    -DcrScope $dcrScope

if ($LASTEXITCODE -ne 0) {
    throw "Permission grants failed"
}
Write-Host ""

# Step 4: Configure Function App
Write-Host "Step 4/7: Configuring Function App..." -ForegroundColor Cyan
& "$ScriptDir/Configure-Function.ps1" `
    -FunctionAppName $config['FUNCTION_APP_NAME'] `
    -ResourceGroupName $config['RESOURCE_GROUP_NAME'] `
    -DcrEndpoint $config['DCR_ENDPOINT_URL'] `
    -DcrRuleId $config['DCR_RULE_ID'] `
    -CosmosEndpoint $config['COSMOS_ENDPOINT']

if ($LASTEXITCODE -ne 0) {
    throw "Function App configuration failed"
}
Write-Host ""

# Step 5: Deploy Function Code
if (-not $SkipFunctionDeploy) {
    Write-Host "Step 5/7: Deploying Function App code..." -ForegroundColor Cyan

    $functionDir = Join-Path $LabRoot "function"

    Push-Location $functionDir
    try {
        func azure functionapp publish $config['FUNCTION_APP_NAME'] --python 2>&1 | ForEach-Object {
            if ($_ -match 'error|failed' -and $_ -notmatch 'SCM_') {
                Write-Host "  $_" -ForegroundColor Red
            } elseif ($_ -match 'Deployment successful|Functions in') {
                Write-Host "  $_" -ForegroundColor Green
            }
        }
    }
    catch {
        # Fallback to zip deploy if func CLI not available
        Write-Host "  func CLI not available, using zip deploy..." -ForegroundColor Yellow

        $zipPath = Join-Path $env:TEMP "function-deploy.zip"
        Compress-Archive -Path "$functionDir/*" -DestinationPath $zipPath -Force

        az functionapp deployment source config-zip `
            --resource-group $config['RESOURCE_GROUP_NAME'] `
            --name $config['FUNCTION_APP_NAME'] `
            --src $zipPath `
            --build-remote true `
            --output none

        Remove-Item $zipPath -Force
        Write-Host "  Deployment complete" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "Step 5/7: Skipping Function App code deployment" -ForegroundColor Yellow
}
Write-Host ""

# Step 6: Seed Cosmos DB
if (-not $SkipSeed) {
    Write-Host "Step 6/7: Seeding Cosmos DB with employee data..." -ForegroundColor Cyan
    & "$ScriptDir/Seed-Data.ps1" `
        -CosmosAccountName $config['COSMOS_ACCOUNT_NAME'] `
        -ResourceGroupName $config['RESOURCE_GROUP_NAME']

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Seed data may have partially failed" -ForegroundColor Yellow
    }
}
else {
    Write-Host "Step 6/7: Skipping Cosmos DB seed data" -ForegroundColor Yellow
}
Write-Host ""

# Step 7: Run smoke test
if (-not $SkipTest) {
    Write-Host "Step 7/7: Running smoke test..." -ForegroundColor Cyan
    & "$ScriptDir/Test-Lab.ps1" -FunctionAppUrl $config['FUNCTION_APP_URL']
}
else {
    Write-Host "Step 7/7: Skipping smoke test" -ForegroundColor Yellow
}

# Summary
Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Function App URL: $($config['FUNCTION_APP_URL'])" -ForegroundColor Cyan
Write-Host ""
Write-Host "Endpoints:"
Write-Host "  Health:   $($config['FUNCTION_APP_URL'])/api/health"
Write-Host "  Evaluate: $($config['FUNCTION_APP_URL'])/api/evaluate"
Write-Host "  Session:  $($config['FUNCTION_APP_URL'])/api/session/{id}"
Write-Host "  Tools:    $($config['FUNCTION_APP_URL'])/api/tools"
Write-Host ""
Write-Host "Demo commands:"
Write-Host "  Attack (local):   ./scripts/Attack-Demo.ps1"
Write-Host "  Defense (live):   ./scripts/Defense-Demo.ps1 -FunctionAppUrl '$($config['FUNCTION_APP_URL'])'"
Write-Host ""
Write-Host "KQL query to verify audit logs:"
Write-Host @"
TrifectaAudit_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SessionId, ToolName, Condition, Decision
| order by TimeGenerated asc
"@ -ForegroundColor DarkGray
Write-Host ""
