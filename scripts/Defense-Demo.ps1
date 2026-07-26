#Requires -Version 7.0
<#
.SYNOPSIS
    Demonstrates authenticated Rule-of-Two enforcement.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^/]+$')]
    [string]$FunctionAppUrl,

    [Parameter(Mandatory)]
    [SecureString]$FunctionKey,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')]
    [string]$SessionId = "demo-$([guid]::NewGuid())"
)

$ErrorActionPreference = 'Stop'
$FunctionAppUrl = $FunctionAppUrl.TrimEnd('/')
$keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($FunctionKey)
try {
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    $authHeaders = @{ 'x-functions-key' = $plainKey }
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    Remove-Variable plainKey -ErrorAction SilentlyContinue
}

function Invoke-GateEvaluation {
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][ValidateSet('ALLOW','BLOCK')][string]$ExpectedDecision
    )
    $body = @{ session_id=$SessionId; tool_name=$ToolName } | ConvertTo-Json -Compress
    $response = Invoke-WebRequest `
        -Uri "$FunctionAppUrl/api/evaluate" `
        -Method Post `
        -Headers $authHeaders `
        -Body $body `
        -ContentType 'application/json' `
        -TimeoutSec 30 `
        -SkipHttpErrorCheck
    $result = $response.Content | ConvertFrom-Json
    $expectedStatus = if ($ExpectedDecision -eq 'ALLOW') { 200 } else { 403 }
    if ($response.StatusCode -ne $expectedStatus -or $result.decision -ne $ExpectedDecision) {
        throw "Expected $ExpectedDecision/$expectedStatus for '$ToolName', got $($result.decision)/$($response.StatusCode)."
    }
    Write-Host "$ToolName -> $($result.decision) ($($result.conditions_after -join ', '))" `
        -ForegroundColor $(if ($ExpectedDecision -eq 'ALLOW') { 'Green' } else { 'Yellow' })
}

try {
    Write-Host "`n=== Authenticated Trifecta Gate Defense Demo ===" -ForegroundColor Cyan
    Invoke-GateEvaluation -ToolName 'read_db' -ExpectedDecision 'ALLOW'
    Invoke-GateEvaluation -ToolName 'process_document' -ExpectedDecision 'ALLOW'
    Invoke-GateEvaluation -ToolName 'send_http' -ExpectedDecision 'BLOCK'

    $session = Invoke-RestMethod `
        -Uri "$FunctionAppUrl/api/session/$SessionId" `
        -Method Get `
        -Headers $authHeaders `
        -TimeoutSec 30
    if ($session.conditions_met -ne 2 -or $session.trifecta_complete) {
        throw 'Defense demo ended outside the safe 2/3 state.'
    }
    Write-Host 'Defense succeeded: the third condition was blocked and not persisted.' -ForegroundColor Green
}
finally {
    $authHeaders['x-functions-key'] = $null
    Remove-Variable authHeaders -ErrorAction SilentlyContinue
}
