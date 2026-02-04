// Lethal Trifecta Lab - Parameters
// Copy this file and customize for your environment

using './main.bicep'

// Required: Deployer's Entra ID object ID (az ad signed-in-user show --query id -o tsv)
param deployerPrincipalId = ''

// Project naming (must be lowercase alphanumeric with hyphens, 3-20 chars)
param projectName = 'trifecta-lab'

// Azure region
param location = 'eastus'

// Optional: Additional tags
param tags = {
  owner: ''
  costCenter: ''
}
