#Requires -Version 7.0
<#
.SYNOPSIS
    Configures the Function App with DCR and Cosmos DB settings.

.DESCRIPTION
    Updates Function App settings with:
    - Data Collection Rule endpoint and ID (for audit logging)
    - Cosmos DB endpoint and database name (for demo data)

.PARAMETER FunctionAppName
    Name of the Function App.

.PARAMETER ResourceGroupName
    Name of the resource group containing the Function App.

.PARAMETER DcrEndpoint
    Data Collection Endpoint URL.

.PARAMETER DcrRuleId
    Data Collection Rule immutable ID (dcr-...).

.PARAMETER CosmosEndpoint
    Cosmos DB account endpoint URL.

.PARAMETER CosmosDatabaseName
    Cosmos DB database name. Default: trifecta-db
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$DcrEndpoint,

    [Parameter(Mandatory)]
    [string]$DcrRuleId,

    [Parameter(Mandatory)]
    [string]$CosmosEndpoint,

    [Parameter()]
    [string]$CosmosDatabaseName = 'trifecta-db'
)

$ErrorActionPreference = 'Stop'

Write-Host "Configuring Function App settings..." -ForegroundColor Yellow

# Build settings array
$settings = @(
    "DCR_ENDPOINT=$DcrEndpoint"
    "DCR_RULE_ID=$DcrRuleId"
    "COSMOS_ENDPOINT=$CosmosEndpoint"
    "COSMOS_DATABASE_NAME=$CosmosDatabaseName"
)

# Update Function App settings
Write-Host "  Updating app settings..." -ForegroundColor Cyan
az functionapp config appsettings set `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --settings $settings `
    --output none 2>$null

if ($LASTEXITCODE -ne 0) {
    throw "Failed to update Function App settings"
}

Write-Host "  Settings configured:" -ForegroundColor Green
foreach ($setting in $settings) {
    $key = ($setting -split '=')[0]
    Write-Host "    - $key" -ForegroundColor Gray
}

Write-Host "Function App configured successfully" -ForegroundColor Green
exit 0
