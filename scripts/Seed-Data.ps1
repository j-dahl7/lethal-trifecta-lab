#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotently seeds clearly synthetic employee records using Entra authentication.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CosmosAccountName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DatabaseName = 'trifecta-db',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName = 'employees',

    [Parameter()]
    [ValidateRange(1, 30)]
    [int]$MaxRetries = 12,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$RetryDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$employees = @(
    @{ id='emp-001'; name='Alice Example'; email='alice@example.invalid'; department='Engineering'; title='Synthetic Engineer'; salary=101001; ssn='000-00-0001'; phone='555-0101' }
    @{ id='emp-002'; name='Bob Example'; email='bob@example.invalid'; department='Engineering'; title='Synthetic DevOps Lead'; salary=101002; ssn='000-00-0002'; phone='555-0102' }
    @{ id='emp-003'; name='Carol Example'; email='carol@example.invalid'; department='Finance'; title='Synthetic Analyst'; salary=101003; ssn='000-00-0003'; phone='555-0103' }
    @{ id='emp-004'; name='David Example'; email='david@example.invalid'; department='Finance'; title='Synthetic Finance Lead'; salary=101004; ssn='000-00-0004'; phone='555-0104' }
    @{ id='emp-005'; name='Eva Example'; email='eva@example.invalid'; department='Security'; title='Synthetic Security Engineer'; salary=101005; ssn='000-00-0005'; phone='555-0105' }
    @{ id='emp-006'; name='Frank Example'; email='frank@example.invalid'; department='Security'; title='Synthetic Security Lead'; salary=101006; ssn='000-00-0006'; phone='555-0106' }
)

$endpoint = az cosmosdb show `
    --name $CosmosAccountName `
    --resource-group $ResourceGroupName `
    --query documentEndpoint `
    --output tsv `
    --only-show-errors
if (-not $endpoint -or $endpoint -notmatch '^https://[^/]+\.documents\.azure\.com(?::\d+)?/?$') {
    throw 'Cosmos DB returned an invalid document endpoint.'
}

$accessToken = az account get-access-token `
    --resource 'https://cosmos.azure.com/' `
    --query accessToken `
    --output tsv `
    --only-show-errors
if (-not $accessToken) {
    throw 'Could not acquire a Cosmos DB data-plane token.'
}
$authorization = [uri]::EscapeDataString("type=aad&ver=1.0&sig=$accessToken")
Remove-Variable accessToken
$documentsUri = "$($endpoint.TrimEnd('/'))/dbs/$DatabaseName/colls/$ContainerName/docs"

Write-Host 'Seeding six clearly synthetic employee records...' -ForegroundColor Yellow
foreach ($employee in $employees) {
    $body = $employee | ConvertTo-Json -Compress
    $succeeded = $false
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $headers = @{
            Authorization = $authorization
            'x-ms-date' = [DateTime]::UtcNow.ToString('R')
            'x-ms-version' = '2018-12-31'
            'x-ms-documentdb-partitionkey' = ('["{0}"]' -f $employee.department)
            'x-ms-documentdb-is-upsert' = 'true'
        }
        try {
            $null = Invoke-RestMethod `
                -Uri $documentsUri `
                -Method Post `
                -Headers $headers `
                -Body $body `
                -ContentType 'application/json' `
                -TimeoutSec 30
            $succeeded = $true
            break
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                throw "Failed to seed synthetic record '$($employee.id)' after $MaxRetries attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    if (-not $succeeded) {
        throw "Failed to seed synthetic record '$($employee.id)'."
    }
}

Write-Host 'Synthetic employee records seeded successfully.' -ForegroundColor Green
