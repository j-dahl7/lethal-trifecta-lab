// Lethal Trifecta Lab - Core Infrastructure
// Deploys: Cosmos DB (serverless) + Key Vault with demo secret

targetScope = 'resourceGroup'

@description('Project name for resource naming')
param projectName string

@description('Azure region')
param location string

@description('Deployer principal ID for Key Vault admin access')
param deployerPrincipalId string

@description('Tags for all resources')
param tags object = {}

// Generate unique suffix for globally unique resource names
var suffix = substring(uniqueString(resourceGroup().id), 0, 6)

// Merge default tags with provided tags
var resourceTags = union({
  project: projectName
  environment: 'lab'
  purpose: 'lethal-trifecta-demo'
}, tags)

// Cosmos DB Account (serverless)
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: '${projectName}-cosmos-${suffix}'
  location: location
  tags: resourceTags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

// Cosmos DB Database
resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: 'trifecta-db'
  properties: {
    resource: {
      id: 'trifecta-db'
    }
  }
}

// Cosmos DB Container - Employees
resource employeesContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: cosmosDatabase
  name: 'employees'
  properties: {
    resource: {
      id: 'employees'
      partitionKey: {
        paths: [
          '/department'
        ]
        kind: 'Hash'
      }
    }
  }
}

// Key Vault - Contains demo secret (represents private data)
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${projectName}-kv-${suffix}'
  location: location
  tags: resourceTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Grant deployer Key Vault Administrator role
resource deployerKvAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerPrincipalId, 'Key Vault Administrator')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '00482a5a-887f-4fb3-b363-3b7fe8e74483') // Key Vault Administrator
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

// Demo secret in Key Vault
resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'employee-api-key'
  properties: {
    value: 'sk-demo-trifecta-lab-do-not-use-in-production'
  }
  dependsOn: [
    deployerKvAdmin
  ]
}

// Outputs
output cosmosAccountId string = cosmosAccount.id
output cosmosAccountName string = cosmosAccount.name
output cosmosAccountEndpoint string = cosmosAccount.properties.documentEndpoint
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
