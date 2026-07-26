#Requires -Version 7.0
<#
.SYNOPSIS
    Configures fail-closed Function App settings without account keys.

.DESCRIPTION
    Sets DCR ingestion and Cosmos endpoint metadata. Cosmos authentication uses
    the Function App managed identity and a container-scoped data-plane role.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^/]+\.ingest\.monitor\.azure\.com/?$')]
    [string]$DcrEndpoint,

    [Parameter(Mandatory)]
    [ValidatePattern('^dcr-[A-Za-z0-9-]{8,128}$')]
    [string]$DcrRuleId,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^/]+\.documents\.azure\.com(?::\d+)?/?$')]
    [string]$CosmosEndpoint,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CosmosDatabaseName = 'trifecta-db'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$settings = @(
    "DCR_ENDPOINT=$($DcrEndpoint.TrimEnd('/'))"
    "DCR_RULE_ID=$DcrRuleId"
    "SESSION_STORE=cosmos"
    "COSMOS_ENDPOINT=$($CosmosEndpoint.TrimEnd('/'))"
    "COSMOS_DATABASE_NAME=$CosmosDatabaseName"
    "COSMOS_CONTAINER_NAME=sessions"
    "AUDIT_REQUIRED=true"
)

Write-Host "Configuring managed-identity Function App settings..." -ForegroundColor Yellow
az functionapp config appsettings set `
    --name $FunctionAppName `
    --resource-group $ResourceGroupName `
    --settings $settings `
    --output none `
    --only-show-errors

Write-Host "Function App configured without Cosmos account keys." -ForegroundColor Green
