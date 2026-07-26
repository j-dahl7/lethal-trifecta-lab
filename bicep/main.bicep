// Lethal Trifecta Lab - Main Orchestrator
// Deploys all Azure infrastructure for the Trifecta Gate
//
// Usage:
//   az deployment sub create --location eastus --template-file main.bicep --parameters main.bicepparam

targetScope = 'subscription'

@description('Project name used for resource naming (lowercase alphanumeric with hyphens)')
@minLength(3)
@maxLength(20)
param projectName string = 'trifecta-lab'

@description('Azure region for all resources')
param location string = 'eastus'

@description('Principal ID of the deployer for scoped Key Vault secret and Cosmos seed access')
param deployerPrincipalId string

@secure()
@description('Generated synthetic secret used only to demonstrate private-data storage')
param demoSecretValue string = newGuid()

@description('Additional tags for all resources')
param tags object = {}

// Resource Group
resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: '${projectName}-rg'
  location: location
  tags: union(tags, {
    project: projectName
    environment: 'lab'
    purpose: 'lethal-trifecta-demo'
    'nlzt-owner': 'lethal-trifecta-lab'
  })
}

// Monitoring Module - Deploy first as other modules depend on Log Analytics
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-deployment'
  scope: resourceGroup
  params: {
    projectName: projectName
    location: location
    tags: tags
  }
}

// Core Module - Cosmos DB + Key Vault
module core 'modules/core.bicep' = {
  name: 'core-deployment'
  scope: resourceGroup
  params: {
    projectName: projectName
    location: location
    deployerPrincipalId: deployerPrincipalId
    demoSecretValue: demoSecretValue
    tags: tags
  }
}

// Function Module - Function App, App Service Plan, App Insights
module function 'modules/function.bicep' = {
  name: 'function-deployment'
  scope: resourceGroup
  params: {
    projectName: projectName
    location: location
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    cosmosEndpoint: core.outputs.cosmosAccountEndpoint
    tags: tags
  }
}

// Data-plane roles are scoped to only the two containers each principal needs.
module permissions 'modules/permissions.bicep' = {
  name: 'data-plane-permissions-deployment'
  scope: resourceGroup
  params: {
    cosmosAccountName: core.outputs.cosmosAccountName
    functionAppPrincipalId: function.outputs.functionAppPrincipalId
    deployerPrincipalId: deployerPrincipalId
  }
}

// Outputs for PowerShell scripts
output resourceGroupName string = resourceGroup.name
output resourceGroupId string = resourceGroup.id

// Core outputs
output cosmosAccountName string = core.outputs.cosmosAccountName
output cosmosAccountEndpoint string = core.outputs.cosmosAccountEndpoint
output keyVaultName string = core.outputs.keyVaultName

// Function outputs
output functionAppId string = function.outputs.functionAppId
output functionAppName string = function.outputs.functionAppName
output functionAppUrl string = function.outputs.functionAppUrl
output functionAppPrincipalId string = function.outputs.functionAppPrincipalId

// Monitoring outputs
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId
output logAnalyticsWorkspaceCustomerId string = monitoring.outputs.logAnalyticsWorkspaceCustomerId
output dataCollectionEndpointUrl string = monitoring.outputs.dataCollectionEndpointUrl

// Subscription context
output tenantId string = subscription().tenantId
output subscriptionId string = subscription().subscriptionId
