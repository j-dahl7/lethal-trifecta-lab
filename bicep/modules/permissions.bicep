// Least-privilege Cosmos DB data-plane roles.

targetScope = 'resourceGroup'

param cosmosAccountName string
param functionAppPrincipalId string
param deployerPrincipalId string

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' existing = {
  name: cosmosAccountName
}

var dataContributorRoleId = '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'

resource functionSessionsContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, functionAppPrincipalId, 'sessions-data-contributor')
  properties: {
    roleDefinitionId: dataContributorRoleId
    principalId: functionAppPrincipalId
    scope: '${cosmosAccount.id}/dbs/trifecta-db/colls/sessions'
  }
}

resource deployerEmployeesContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, deployerPrincipalId, 'employees-data-contributor')
  properties: {
    roleDefinitionId: dataContributorRoleId
    principalId: deployerPrincipalId
    scope: '${cosmosAccount.id}/dbs/trifecta-db/colls/employees'
  }
}

output functionSessionsRoleAssignmentId string = functionSessionsContributor.id
output deployerEmployeesRoleAssignmentId string = deployerEmployeesContributor.id
