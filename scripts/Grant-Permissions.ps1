#Requires -Version 7.0
<#
.SYNOPSIS
    Grants Monitoring Metrics Publisher role to the Function App managed identity on the DCR.

.DESCRIPTION
    Unlike the ZSP lab, the Trifecta lab only needs a single RBAC permission:
    - Monitoring Metrics Publisher on the Data Collection Rule (for audit log ingestion)

    No Graph API permissions or Entra ID setup required.

.PARAMETER FunctionAppPrincipalId
    Object ID of the Function App's managed identity.

.PARAMETER DcrScope
    Resource ID of the Data Collection Rule.

.PARAMETER MaxRetries
    Maximum retry attempts for propagation delays. Default: 5

.PARAMETER RetryDelaySeconds
    Seconds to wait between retries. Default: 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppPrincipalId,

    [Parameter(Mandatory)]
    [string]$DcrScope,

    [Parameter()]
    [int]$MaxRetries = 5,

    [Parameter()]
    [int]$RetryDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'

Write-Host "Granting permissions to Function App managed identity..." -ForegroundColor Yellow

# Grant Monitoring Metrics Publisher on DCR (for audit log ingestion)
Write-Host "  Granting Monitoring Metrics Publisher on DCR..." -ForegroundColor Cyan
$existingMonitor = az role assignment list `
    --assignee $FunctionAppPrincipalId `
    --scope $DcrScope `
    --role "Monitoring Metrics Publisher" `
    --output json 2>$null | ConvertFrom-Json

if ($existingMonitor -and $existingMonitor.Count -gt 0) {
    Write-Host "    Already granted" -ForegroundColor Green
}
else {
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            az role assignment create `
                --assignee-object-id $FunctionAppPrincipalId `
                --assignee-principal-type ServicePrincipal `
                --role "Monitoring Metrics Publisher" `
                --scope $DcrScope `
                --output none 2>$null
            Write-Host "    Granted" -ForegroundColor Green
            break
        }
        catch {
            if ($i -eq $MaxRetries) {
                throw "Failed to grant Monitoring Metrics Publisher after $MaxRetries attempts"
            }
            Write-Host "    Retry $i/$MaxRetries..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

Write-Host "Permissions granted successfully" -ForegroundColor Green
exit 0
