#Requires -Version 7.0
<#
.SYNOPSIS
    Seeds Cosmos DB with fake employee records for the demo.

.DESCRIPTION
    Inserts ~6 fake employee records into the Cosmos DB employees container.
    These represent the private data that the trifecta attack targets.

.PARAMETER CosmosAccountName
    Name of the Cosmos DB account.

.PARAMETER ResourceGroupName
    Name of the resource group.

.PARAMETER DatabaseName
    Cosmos DB database name. Default: trifecta-db

.PARAMETER ContainerName
    Cosmos DB container name. Default: employees
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CosmosAccountName,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$DatabaseName = 'trifecta-db',

    [Parameter()]
    [string]$ContainerName = 'employees'
)

$ErrorActionPreference = 'Stop'

Write-Host "Seeding Cosmos DB with demo employee data..." -ForegroundColor Yellow

# Fake employee records
$employees = @(
    @{
        id = "emp-001"
        name = "Alice Johnson"
        email = "alice.johnson@contoso.com"
        department = "Engineering"
        title = "Senior Software Engineer"
        salary = 145000
        ssn = "123-45-6789"
        phone = "555-0101"
    }
    @{
        id = "emp-002"
        name = "Bob Martinez"
        email = "bob.martinez@contoso.com"
        department = "Engineering"
        title = "DevOps Lead"
        salary = 155000
        ssn = "234-56-7890"
        phone = "555-0102"
    }
    @{
        id = "emp-003"
        name = "Carol Chen"
        email = "carol.chen@contoso.com"
        department = "Finance"
        title = "Financial Analyst"
        salary = 120000
        ssn = "345-67-8901"
        phone = "555-0103"
    }
    @{
        id = "emp-004"
        name = "David Kim"
        email = "david.kim@contoso.com"
        department = "Finance"
        title = "VP of Finance"
        salary = 210000
        ssn = "456-78-9012"
        phone = "555-0104"
    }
    @{
        id = "emp-005"
        name = "Eva Rodriguez"
        email = "eva.rodriguez@contoso.com"
        department = "Security"
        title = "Security Engineer"
        salary = 160000
        ssn = "567-89-0123"
        phone = "555-0105"
    }
    @{
        id = "emp-006"
        name = "Frank Thompson"
        email = "frank.thompson@contoso.com"
        department = "Security"
        title = "CISO"
        salary = 250000
        ssn = "678-90-1234"
        phone = "555-0106"
    }
)

# Get Cosmos DB key
Write-Host "  Retrieving Cosmos DB key..." -ForegroundColor Cyan
$keys = az cosmosdb keys list `
    --name $CosmosAccountName `
    --resource-group $ResourceGroupName `
    --output json 2>$null | ConvertFrom-Json

if (-not $keys) {
    throw "Failed to retrieve Cosmos DB keys"
}

$cosmosKey = $keys.primaryMasterKey
$cosmosEndpoint = (az cosmosdb show --name $CosmosAccountName --resource-group $ResourceGroupName --query documentEndpoint -o tsv 2>$null)

$inserted = 0
foreach ($emp in $employees) {
    $body = $emp | ConvertTo-Json -Compress

    Write-Host "  Inserting $($emp.name) ($($emp.department))..." -ForegroundColor Cyan

    # Use az cosmosdb sql container create-item (or REST API)
    try {
        az cosmosdb sql database container-item create `
            --account-name $CosmosAccountName `
            --resource-group $ResourceGroupName `
            --database-name $DatabaseName `
            --container-name $ContainerName `
            --body $body `
            --output none 2>$null

        if ($LASTEXITCODE -ne 0) {
            # Fallback: use REST API via az rest
            $partitionKey = "[`"$($emp.department)`"]"
            az rest --method POST `
                --uri "$cosmosEndpoint/dbs/$DatabaseName/colls/$ContainerName/docs" `
                --headers "Content-Type=application/json" "x-ms-version=2018-12-31" "x-ms-documentdb-partitionkey=$partitionKey" `
                --body $body `
                --output none 2>$null
        }

        $inserted++
        Write-Host "    Inserted" -ForegroundColor Green
    }
    catch {
        Write-Host "    Warning: $($_.Exception.Message)" -ForegroundColor Yellow
        # Continue with remaining records
    }
}

Write-Host ""
Write-Host "Seeded $inserted/$($employees.Count) employee records" -ForegroundColor $(if ($inserted -eq $employees.Count) { 'Green' } else { 'Yellow' })
exit 0
