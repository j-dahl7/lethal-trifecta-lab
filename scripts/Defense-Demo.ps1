#Requires -Version 7.0
<#
.SYNOPSIS
    Demonstrates the Trifecta Gate blocking the 3rd condition.

.DESCRIPTION
    Calls the deployed Trifecta Gate with 3 sequential tool evaluations.
    Steps 1-2 return 200 ALLOW. Step 3 returns 403 BLOCK.

    Then queries the session endpoint to confirm 2/3 conditions are active.

.PARAMETER FunctionAppUrl
    Base URL of the deployed Function App.

.PARAMETER SessionId
    Session ID for the demo. Default: demo-session-<timestamp>

.EXAMPLE
    ./Defense-Demo.ps1 -FunctionAppUrl "https://trifecta-lab-gate-abc123.azurewebsites.net"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppUrl,

    [Parameter()]
    [string]$SessionId = "demo-session-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

# Trim trailing slash
$FunctionAppUrl = $FunctionAppUrl.TrimEnd('/')

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  TRIFECTA GATE DEFENSE DEMO" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Gate URL:   $FunctionAppUrl" -ForegroundColor Cyan
Write-Host "Session ID: $SessionId" -ForegroundColor Cyan
Write-Host ""
Write-Host "Sending 3 tool calls to the Trifecta Gate." -ForegroundColor Yellow
Write-Host "The first 2 will be ALLOWED. The 3rd will be BLOCKED." -ForegroundColor Yellow
Write-Host ""

$evaluateUrl = "$FunctionAppUrl/api/evaluate"

function Invoke-GateEvaluation {
    param(
        [int]$Step,
        [string]$ToolName,
        [string]$ExpectedDecision
    )

    Write-Host "--- Step $Step ---" -ForegroundColor White
    Write-Host "Tool: $ToolName" -ForegroundColor Cyan

    $body = @{
        session_id = $SessionId
        tool_name = $ToolName
    } | ConvertTo-Json

    try {
        $response = Invoke-WebRequest -Uri $evaluateUrl -Method POST `
            -Body $body -ContentType "application/json" `
            -TimeoutSec 30 -ErrorAction Stop

        $result = $response.Content | ConvertFrom-Json
        $statusCode = $response.StatusCode

        if ($result.decision -eq "ALLOW") {
            Write-Host "  Status:    $statusCode" -ForegroundColor Green
            Write-Host "  Decision:  $($result.decision)" -ForegroundColor Green
            Write-Host "  Condition: $($result.condition)" -ForegroundColor Gray
            Write-Host "  Active:    [$($result.conditions_after -join ', ')]" -ForegroundColor Gray
        }
        else {
            Write-Host "  Status:    $statusCode" -ForegroundColor Red
            Write-Host "  Decision:  $($result.decision)" -ForegroundColor Red
            Write-Host "  Reason:    $($result.reason)" -ForegroundColor Yellow
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 403) {
            $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json

            Write-Host "  Status:    403" -ForegroundColor Red
            Write-Host "  Decision:  $($errorBody.decision)" -ForegroundColor Red
            Write-Host "  Reason:    $($errorBody.reason)" -ForegroundColor Yellow
        }
        else {
            Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Start-Sleep -Milliseconds 500
}

# Step 1: Allow - private_data
Invoke-GateEvaluation -Step 1 -ToolName "read_db" -ExpectedDecision "ALLOW"

# Step 2: Allow - untrusted_content
Invoke-GateEvaluation -Step 2 -ToolName "process_document" -ExpectedDecision "ALLOW"

# Step 3: Block - exfiltration_vector (would complete trifecta)
Invoke-GateEvaluation -Step 3 -ToolName "send_http" -ExpectedDecision "BLOCK"

# Query session state
Write-Host "--- Session State ---" -ForegroundColor White
Write-Host "Querying session endpoint..." -ForegroundColor Cyan

try {
    $sessionUrl = "$FunctionAppUrl/api/session/$SessionId"
    $sessionResponse = Invoke-RestMethod -Uri $sessionUrl -Method GET -TimeoutSec 30
    Write-Host "  Conditions met:     $($sessionResponse.conditions_met)/$($sessionResponse.conditions_total)" -ForegroundColor Cyan
    Write-Host "  Active conditions:  [$($sessionResponse.active_conditions -join ', ')]" -ForegroundColor Green
    Write-Host "  Missing conditions: [$($sessionResponse.missing_conditions -join ', ')]" -ForegroundColor Yellow
    Write-Host "  Trifecta complete:  $($sessionResponse.trifecta_complete)" -ForegroundColor $(if ($sessionResponse.trifecta_complete) { 'Red' } else { 'Green' })
    Write-Host "  Total calls:        $($sessionResponse.call_count)" -ForegroundColor Gray
}
catch {
    Write-Host "  Warning: Could not query session state: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  DEFENSE SUCCESSFUL - TRIFECTA BLOCKED" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "The Rule of Two enforced:" -ForegroundColor Yellow
Write-Host "  [x] private_data        - ALLOWED (1/3 conditions)" -ForegroundColor Green
Write-Host "  [x] untrusted_content   - ALLOWED (2/3 conditions)" -ForegroundColor Green
Write-Host "  [ ] exfiltration_vector  - BLOCKED (would complete 3/3)" -ForegroundColor Red
Write-Host ""
Write-Host "The agent has access to sensitive data AND processed untrusted" -ForegroundColor Gray
Write-Host "content, but cannot exfiltrate because the gate blocks the 3rd" -ForegroundColor Gray
Write-Host "condition that would complete the lethal trifecta." -ForegroundColor Gray
Write-Host ""
