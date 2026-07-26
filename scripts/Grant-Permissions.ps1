#Requires -Version 7.0
<#
.SYNOPSIS
    Grants DCR-scoped ingestion permission to the Function App identity.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$FunctionAppPrincipalId,

    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/dataCollectionRules/[^/]+$')]
    [string]$DcrScope,

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$MaxRetries = 12,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$MonitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

Write-Host "Granting DCR-scoped audit ingestion permission..." -ForegroundColor Yellow
$existing = @(
    az role assignment list `
        --assignee $FunctionAppPrincipalId `
        --scope $DcrScope `
        --role $MonitoringMetricsPublisherRoleId `
        --output json `
        --only-show-errors | ConvertFrom-Json
)

if ($existing.Count -gt 0) {
    Write-Host "  Permission already granted." -ForegroundColor Green
    return
}

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
        az role assignment create `
            --assignee-object-id $FunctionAppPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $MonitoringMetricsPublisherRoleId `
            --scope $DcrScope `
            --output none `
            --only-show-errors
        Write-Host "  Permission granted." -ForegroundColor Green
        return
    }
    catch {
        if ($attempt -eq $MaxRetries) {
            throw "Failed to grant DCR permission after $MaxRetries attempts: $($_.Exception.Message)"
        }
        Write-Host "  Waiting for managed-identity propagation ($attempt/$MaxRetries)..." -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}
