#Requires -Version 7.0
<#
.SYNOPSIS
    Removes only an exactly named and fully ownership-tagged lab resource group.

.DESCRIPTION
    Fails closed if the resource group identity or any top-level resource lacks
    the immutable lab ownership tags. Use -WhatIf before deletion.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter()]
    [ValidatePattern('^[a-z0-9](?:[a-z0-9-]{1,18}[a-z0-9])$')]
    [string]$ProjectName = 'trifecta-lab',

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$OwnerMarker = 'lethal-trifecta-lab'
$resourceGroupName = "$ProjectName-rg"
$account = az account show --output json --only-show-errors | ConvertFrom-Json
if (-not $SubscriptionId) {
    $SubscriptionId = $account.id
}
if ($account.id -ne $SubscriptionId) {
    throw "Active subscription '$($account.id)' does not match requested subscription '$SubscriptionId'."
}

$exists = az group exists `
    --name $resourceGroupName `
    --subscription $SubscriptionId `
    --output tsv `
    --only-show-errors
if ($exists -ne 'true') {
    Write-Host "Resource group '$resourceGroupName' does not exist; nothing to remove." -ForegroundColor Yellow
    return
}

$group = az group show `
    --name $resourceGroupName `
    --subscription $SubscriptionId `
    --output json `
    --only-show-errors | ConvertFrom-Json

$groupOwned =
    $group.name -ceq $resourceGroupName -and
    $group.tags.'nlzt-owner' -ceq $OwnerMarker -and
    $group.tags.project -ceq $ProjectName -and
    $group.tags.environment -ceq 'lab' -and
    $group.tags.purpose -ceq 'lethal-trifecta-demo'
if (-not $groupOwned) {
    throw "Refusing cleanup: resource group '$resourceGroupName' does not have the exact lab ownership identity."
}

$resources = @(
    az resource list `
        --resource-group $resourceGroupName `
        --subscription $SubscriptionId `
        --output json `
        --only-show-errors | ConvertFrom-Json
)
$topLevelTaggableResources = @(
    $resources | Where-Object {
        $providerPath = ($_.id -split '/providers/', 2)[-1]
        ($providerPath -split '/').Count -eq 3 -and
        $_.type -ne 'Microsoft.Authorization/roleAssignments'
    }
)
$foreignResources = @(
    $topLevelTaggableResources | Where-Object {
        $_.tags.'nlzt-owner' -cne $OwnerMarker -or $_.tags.project -cne $ProjectName
    }
)
if ($foreignResources.Count -gt 0) {
    $identifiers = ($foreignResources | ForEach-Object { $_.id }) -join ', '
    throw "Refusing cleanup: the resource group contains unowned or foreign top-level resources: $identifiers"
}

$target = "/subscriptions/$SubscriptionId/resourceGroups/$resourceGroupName"
if ($PSCmdlet.ShouldProcess($target, 'Delete fully ownership-validated lab resource group')) {
    $arguments = @(
        'group', 'delete',
        '--name', $resourceGroupName,
        '--subscription', $SubscriptionId,
        '--yes',
        '--only-show-errors'
    )
    if ($NoWait) { $arguments += '--no-wait' }
    az @arguments
    Write-Host "Owned lab resource-group deletion $(if ($NoWait) { 'submitted' } else { 'completed' })." -ForegroundColor Green
} elseif ($WhatIfPreference) {
    Write-Host 'Cleanup preview complete; no resources were deleted.' -ForegroundColor Green
}
