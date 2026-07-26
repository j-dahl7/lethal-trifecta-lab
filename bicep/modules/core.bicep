// Lethal Trifecta Lab - Core Infrastructure
// Deploys: Cosmos DB (serverless) + Key Vault with demo secret

targetScope = 'resourceGroup'

@description('Project name for resource naming')
param projectName string

@description('Azure region')
param location string

@description('Deployer principal ID for scoped Key Vault secret access')
param deployerPrincipalId string

@secure()
@description('Synthetic generated value for the lab-only Key Vault secret')
param demoSecretValue string

@description('Tags for all resources')
param tags object = {}

// Generate unique suffix for globally unique resource names
var suffix = substring(uniqueString(resourceGroup().id), 0, 6)

// Merge default tags with provided tags
var resourceTags = union(tags, {
  project: projectName
  environment: 'lab'
  purpose: 'lethal-trifecta-demo'
  'nlzt-owner': 'lethal-trifecta-lab'
})

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
    disableLocalAuth: true
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

// Cosmos DB Container - Sessions (for gate session state persistence)
resource sessionsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: cosmosDatabase
  name: 'sessions'
  properties: {
    resource: {
      id: 'sessions'
      partitionKey: {
        paths: [
          '/session_id'
        ]
        kind: 'Hash'
      }
      defaultTtl: 86400 // Sessions expire after 24 hours
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

// Grant only secret-management access; the deployer does not need vault administration.
resource deployerKvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployerPrincipalId, 'Key Vault Secrets Officer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

// Demo secret in Key Vault
resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'employee-api-key'
  properties: {
    value: demoSecretValue
  }
  dependsOn: [
    deployerKvSecretsOfficer
  ]
}

// Outputs
output cosmosAccountId string = cosmosAccount.id
output cosmosAccountName string = cosmosAccount.name
output cosmosAccountEndpoint string = cosmosAccount.properties.documentEndpoint
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
