#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys Azure infrastructure using Bicep templates.

.DESCRIPTION
    Deploys the following Azure resources:
    - Resource Group
    - Cosmos DB (serverless) with employees container
    - Key Vault with demo secret
    - Function App (Linux, Python 3.11, Flex Consumption)
    - Application Insights
    - Log Analytics Workspace
    - Data Collection Endpoint

.PARAMETER ProjectName
    Project name for resource naming.

.PARAMETER Location
    Azure region for deployment.

.PARAMETER DeployerPrincipalId
    Object ID of the deployer for Key Vault admin access.

.OUTPUTS
    Key=Value pairs for use by other scripts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$DeployerPrincipalId
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BicepDir = Join-Path (Split-Path -Parent $ScriptDir) "bicep"

Write-Host "Deploying Azure resources..." -ForegroundColor Yellow

# Deploy at subscription scope
$deploymentName = "trifecta-lab-$(Get-Date -Format 'yyyyMMddHHmmss')"

$stderrFile = [System.IO.Path]::GetTempFileName()
$deployment = az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file "$BicepDir/main.bicep" `
    --parameters projectName=$ProjectName `
    --parameters location=$Location `
    --parameters deployerPrincipalId=$DeployerPrincipalId `
    --output json 2>$stderrFile

if ($LASTEXITCODE -ne 0) {
    $stderrContent = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    Write-Error "Bicep deployment failed: $stderrContent"
    exit 1
}
Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue

$result = $deployment | ConvertFrom-Json

if ($result.properties.provisioningState -ne 'Succeeded') {
    Write-Error "Deployment failed with state: $($result.properties.provisioningState)"
    exit 1
}

$outputs = $result.properties.outputs

# Output configuration for other scripts
Write-Output "RESOURCE_GROUP_NAME=$($outputs.resourceGroupName.value)"
Write-Output "RESOURCE_GROUP_ID=$($outputs.resourceGroupId.value)"
Write-Output "FUNCTION_APP_NAME=$($outputs.functionAppName.value)"
Write-Output "FUNCTION_APP_URL=$($outputs.functionAppUrl.value)"
Write-Output "FUNCTION_APP_PRINCIPAL_ID=$($outputs.functionAppPrincipalId.value)"
Write-Output "COSMOS_ACCOUNT_NAME=$($outputs.cosmosAccountName.value)"
Write-Output "COSMOS_ENDPOINT=$($outputs.cosmosAccountEndpoint.value)"
Write-Output "KEYVAULT_NAME=$($outputs.keyVaultName.value)"
Write-Output "LOG_ANALYTICS_WORKSPACE_ID=$($outputs.logAnalyticsWorkspaceId.value)"
Write-Output "LOG_ANALYTICS_WORKSPACE_CUSTOMER_ID=$($outputs.logAnalyticsWorkspaceCustomerId.value)"
Write-Output "DCR_ENDPOINT_URL=$($outputs.dataCollectionEndpointUrl.value)"
Write-Output "TENANT_ID=$($outputs.tenantId.value)"
Write-Output "SUBSCRIPTION_ID=$($outputs.subscriptionId.value)"

Write-Host "Azure resources deployed successfully" -ForegroundColor Green
exit 0
