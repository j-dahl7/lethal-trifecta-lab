// Lethal Trifecta Lab - Function App Infrastructure
// Deploys: Function App (Flex Consumption), Storage Account, App Insights

targetScope = 'resourceGroup'

@description('Project name for resource naming')
param projectName string

@description('Azure region')
param location string

@description('Log Analytics Workspace ID for App Insights')
param logAnalyticsWorkspaceId string

@description('Cosmos DB endpoint used with the Function App managed identity')
param cosmosEndpoint string

@description('Tags for all resources')
param tags object = {}

// Generate unique suffix for globally unique resource names
var suffix = substring(uniqueString(resourceGroup().id), 0, 6)

// Merge default tags
var resourceTags = union(tags, {
  project: projectName
  environment: 'lab'
  purpose: 'lethal-trifecta-demo'
  'nlzt-owner': 'lethal-trifecta-lab'
})

// Storage account for Function App (Flex Consumption requires blob containers)
resource functionStorage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${replace(projectName, '-', '')}fn${suffix}'
  location: location
  tags: resourceTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
  }
}

// Blob service for Flex Consumption
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: functionStorage
  name: 'default'
}

// Deployment container for Flex Consumption
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}

// Flex Consumption App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${projectName}-plan'
  location: location
  tags: resourceTags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Required for Linux
  }
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${projectName}-insights'
  location: location
  tags: resourceTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspaceId
  }
}

// Function App with Flex Consumption
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: '${projectName}-gate-${suffix}'
  location: location
  tags: resourceTags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}deployments'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 5
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SESSION_STORE'
          value: 'cosmos'
        }
        {
          name: 'COSMOS_ENDPOINT'
          value: cosmosEndpoint
        }
        {
          name: 'COSMOS_DATABASE_NAME'
          value: 'trifecta-db'
        }
        {
          name: 'COSMOS_CONTAINER_NAME'
          value: 'sessions'
        }
        {
          name: 'AUDIT_REQUIRED'
          value: 'true'
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// Host coordination and deployment package access, scoped to this storage account.
resource functionStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, functionApp.name, 'Storage Blob Data Owner')
  scope: functionStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2022-03-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2022-03-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

// Outputs
output functionAppId string = functionApp.id
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionAppPrincipalId string = functionApp.identity.principalId
output appInsightsConnectionString string = appInsights.properties.ConnectionString
