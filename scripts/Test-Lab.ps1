#Requires -Version 7.0
<#
.SYNOPSIS
    Runs smoke tests on the deployed Trifecta Gate.

.DESCRIPTION
    Tests the following functionality:
    1. Health endpoint returns 200
    2. Tools endpoint returns 7 tools
    3. Single tool call is allowed
    4. Trifecta sequence is blocked on 3rd call
    5. Session state shows 2/3 conditions

.PARAMETER FunctionAppUrl
    Base URL of the Function App.

.EXAMPLE
    ./Test-Lab.ps1 -FunctionAppUrl "https://trifecta-lab-gate-abc123.azurewebsites.net"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FunctionAppUrl
)

$ErrorActionPreference = 'Stop'

# Trim trailing slash
$FunctionAppUrl = $FunctionAppUrl.TrimEnd('/')

Write-Host "`n=== Trifecta Gate Smoke Tests ===" -ForegroundColor Cyan

$passed = 0
$failed = 0

# Test 1: Health endpoint
Write-Host "`nTest 1: Health endpoint" -ForegroundColor Yellow
try {
    $healthUrl = "$FunctionAppUrl/api/health"
    $healthResponse = Invoke-RestMethod -Uri $healthUrl -Method GET -TimeoutSec 60

    if ($healthResponse.status -eq 'healthy' -and $healthResponse.service -eq 'trifecta-gate') {
        Write-Host "  PASSED: Health check returned healthy" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "  FAILED: Unexpected health status: $($healthResponse | ConvertTo-Json -Compress)" -ForegroundColor Red
        $failed++
    }
}
catch {
    Write-Host "  FAILED: Health check error: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

# Test 2: Tools endpoint
Write-Host "`nTest 2: Tools endpoint" -ForegroundColor Yellow
try {
    $toolsUrl = "$FunctionAppUrl/api/tools"
    $toolsResponse = Invoke-RestMethod -Uri $toolsUrl -Method GET -TimeoutSec 60

    if ($toolsResponse.tools.Count -eq 7) {
        Write-Host "  PASSED: Returned 7 tools" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "  FAILED: Expected 7 tools, got $($toolsResponse.tools.Count)" -ForegroundColor Red
        $failed++
    }
}
catch {
    Write-Host "  FAILED: Tools endpoint error: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

# Test 3: Single tool call allowed
Write-Host "`nTest 3: Single tool call (ALLOW)" -ForegroundColor Yellow
$testSessionId = "smoke-test-$(Get-Date -Format 'yyyyMMddHHmmss')"
try {
    $evaluateUrl = "$FunctionAppUrl/api/evaluate"
    $body = @{ session_id = $testSessionId; tool_name = "read_db" } | ConvertTo-Json
    $evalResponse = Invoke-RestMethod -Uri $evaluateUrl -Method POST -Body $body -ContentType "application/json" -TimeoutSec 60

    if ($evalResponse.decision -eq 'ALLOW') {
        Write-Host "  PASSED: read_db allowed (1/3 conditions)" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "  FAILED: Expected ALLOW, got $($evalResponse.decision)" -ForegroundColor Red
        $failed++
    }
}
catch {
    Write-Host "  FAILED: Evaluate error: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

# Test 4: Trifecta block on 3rd call
Write-Host "`nTest 4: Trifecta block sequence" -ForegroundColor Yellow
try {
    # Second call - untrusted_content (should be ALLOW)
    $body2 = @{ session_id = $testSessionId; tool_name = "process_document" } | ConvertTo-Json
    $eval2 = Invoke-RestMethod -Uri $evaluateUrl -Method POST -Body $body2 -ContentType "application/json" -TimeoutSec 60

    if ($eval2.decision -ne 'ALLOW') {
        Write-Host "  FAILED: process_document should be ALLOW, got $($eval2.decision)" -ForegroundColor Red
        $failed++
    }
    else {
        # Third call - exfiltration_vector (should be BLOCK)
        $body3 = @{ session_id = $testSessionId; tool_name = "send_http" } | ConvertTo-Json
        $blocked = $false

        try {
            $eval3 = Invoke-WebRequest -Uri $evaluateUrl -Method POST -Body $body3 -ContentType "application/json" -TimeoutSec 60
            # If we get here with a 200, something is wrong
            Write-Host "  FAILED: send_http should be BLOCKED (403), got $($eval3.StatusCode)" -ForegroundColor Red
            $failed++
        }
        catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 403) {
                Write-Host "  PASSED: send_http blocked with 403 (trifecta prevented)" -ForegroundColor Green
                $passed++
                $blocked = $true
            }
            else {
                Write-Host "  FAILED: Expected 403, got error: $($_.Exception.Message)" -ForegroundColor Red
                $failed++
            }
        }
    }
}
catch {
    Write-Host "  FAILED: Trifecta block sequence error: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

# Test 5: Session state
Write-Host "`nTest 5: Session state" -ForegroundColor Yellow
try {
    $sessionUrl = "$FunctionAppUrl/api/session/$testSessionId"
    $sessionResponse = Invoke-RestMethod -Uri $sessionUrl -Method GET -TimeoutSec 60

    if ($sessionResponse.conditions_met -eq 2 -and -not $sessionResponse.trifecta_complete) {
        Write-Host "  PASSED: Session shows 2/3 conditions, trifecta not complete" -ForegroundColor Green
        $passed++
    }
    else {
        Write-Host "  FAILED: Expected 2/3 conditions, got $($sessionResponse.conditions_met)/3 (complete: $($sessionResponse.trifecta_complete))" -ForegroundColor Red
        $failed++
    }
}
catch {
    Write-Host "  FAILED: Session state error: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}

# Summary
Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })

if ($failed -gt 0) {
    exit 1
}
exit 0
