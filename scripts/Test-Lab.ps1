#Requires -Version 7.0
<#
.SYNOPSIS
    Runs authenticated end-to-end smoke tests against the deployed gate.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://[^/]+$')]
    [string]$FunctionAppUrl,

    [Parameter(Mandatory)]
    [SecureString]$FunctionKey
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

function Invoke-Gate {
    param([string]$ToolName, [string]$SessionId)
    $body = @{ session_id=$SessionId; tool_name=$ToolName } | ConvertTo-Json -Compress
    $response = Invoke-WebRequest `
        -Uri "$FunctionAppUrl/api/evaluate" `
        -Method Post `
        -Headers $authHeaders `
        -Body $body `
        -ContentType 'application/json' `
        -TimeoutSec 60 `
        -SkipHttpErrorCheck
    return [pscustomobject]@{
        StatusCode = $response.StatusCode
        Body = $response.Content | ConvertFrom-Json
    }
}

try {
    $health = $null
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $healthResponse = Invoke-WebRequest `
            -Uri "$FunctionAppUrl/api/health" `
            -Method Get `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck
        $health = $healthResponse.Content | ConvertFrom-Json
        if ($healthResponse.StatusCode -eq 200 -and $health.status -eq 'healthy') { break }
        if ($attempt -eq 18) {
            throw "Health endpoint did not become ready: $($healthResponse.Content)"
        }
        Start-Sleep -Seconds 10
    }

    $tools = Invoke-RestMethod `
        -Uri "$FunctionAppUrl/api/tools" `
        -Method Get `
        -Headers $authHeaders `
        -TimeoutSec 60
    if ($tools.tools.Count -ne 7) { throw 'Authenticated registry did not return seven tools.' }

    $sessionId = "smoke-$([guid]::NewGuid())"
    $first = Invoke-Gate -ToolName 'read_db' -SessionId $sessionId
    $second = Invoke-Gate -ToolName 'process_document' -SessionId $sessionId
    $third = Invoke-Gate -ToolName 'send_http' -SessionId $sessionId
    if ($first.StatusCode -ne 200 -or $first.Body.decision -ne 'ALLOW') {
        throw 'First registered condition was not allowed.'
    }
    if ($second.StatusCode -ne 200 -or $second.Body.decision -ne 'ALLOW') {
        throw 'Second registered condition was not allowed.'
    }
    if ($third.StatusCode -ne 403 -or $third.Body.decision -ne 'BLOCK') {
        throw 'Third condition was not blocked with HTTP 403.'
    }

    $session = Invoke-RestMethod `
        -Uri "$FunctionAppUrl/api/session/$sessionId" `
        -Method Get `
        -Headers $authHeaders `
        -TimeoutSec 60
    if ($session.conditions_met -ne 2 -or $session.trifecta_complete) {
        throw 'Persisted session state was not the expected safe 2/3 state.'
    }
    Write-Host 'Authenticated smoke tests passed.' -ForegroundColor Green
}
finally {
    $authHeaders['x-functions-key'] = $null
    Remove-Variable authHeaders -ErrorAction SilentlyContinue
}
