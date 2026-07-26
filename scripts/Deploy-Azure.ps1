#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the owned Azure resource group and emits validated key/value outputs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{1,18}[a-z0-9])$')]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+$')]
    [string]$Location,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$DeployerPrincipalId
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BicepDir = Join-Path (Split-Path -Parent $ScriptDir) 'bicep'
$deploymentName = "trifecta-lab-$(Get-Date -Format 'yyyyMMddHHmmss')"
$stderrFile = New-TemporaryFile

try {
    $deploymentJson = az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file (Join-Path $BicepDir 'main.bicep') `
        --parameters projectName=$ProjectName `
        --parameters location=$Location `
        --parameters deployerPrincipalId=$DeployerPrincipalId `
        --output json `
        --only-show-errors 2>$($stderrFile.FullName)
}
catch {
    $details = Get-Content -LiteralPath $stderrFile.FullName -Raw -ErrorAction SilentlyContinue
    throw "Bicep deployment failed. $details"
}
finally {
    Remove-Item -LiteralPath $stderrFile.FullName -Force -ErrorAction SilentlyContinue
}

try {
    $result = $deploymentJson | ConvertFrom-Json -Depth 100
} catch {
    throw 'Azure deployment returned invalid JSON.'
}
if ($result.properties.provisioningState -ne 'Succeeded') {
    throw "Deployment failed with state '$($result.properties.provisioningState)'."
}

$outputs = $result.properties.outputs
$requiredOutputs = @(
    'resourceGroupName', 'resourceGroupId', 'functionAppName', 'functionAppUrl',
    'functionAppPrincipalId', 'cosmosAccountName', 'cosmosAccountEndpoint',
    'keyVaultName', 'logAnalyticsWorkspaceId', 'logAnalyticsWorkspaceCustomerId',
    'dataCollectionEndpointUrl', 'tenantId', 'subscriptionId'
)
foreach ($name in $requiredOutputs) {
    if (-not $outputs.$name.value) {
        throw "Azure deployment output '$name' is missing."
    }
}

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
