---
skill: apex-azure
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# Azure — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Create service principals with client secret credentials that don't rotate — use Managed Identity or Workload Identity Federation
- Use `Owner` or `Contributor` on a subscription when a smaller scope suffices
- Store connection strings in app settings as plaintext — use Key Vault references
- Skip resource locks on production resources (`CannotDelete` at minimum)
- Deploy to the default resource group without environment/project naming convention
- Use App Service Free or Shared tiers in production — Basic is the minimum for SLA

ALWAYS:
- Use Managed Identity for service-to-service auth — no credentials in code
- Tag every resource: `Environment`, `Project`, `Team`, `ManagedBy`
- Use Key Vault references in App Service config: `@Microsoft.KeyVault(SecretUri=...)`
- Enable diagnostic settings on critical resources → Log Analytics Workspace
- Use `azurerm_user_assigned_identity` over system-assigned for portability

## Bicep — resource patterns

```bicep
// main.bicep — parameterised deployment
@description('Environment: dev, staging, prod')
param environment string

@description('Azure region')
param location string = resourceGroup().location

var commonTags = {
  Environment: environment
  Project: 'myapp'
  ManagedBy: 'bicep'
  Team: 'platform'
}

// User-assigned managed identity (preferred over system-assigned)
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-myapp-${environment}'
  location: location
  tags: commonTags
}

// Key Vault — RBAC model (not access policies)
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-myapp-${environment}-${uniqueString(resourceGroup().id)}'
  location: location
  tags: commonTags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Grant managed identity Key Vault Secrets User role
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, identity.id, 'Key Vault Secrets User')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
```

## Terraform — Azure provider patterns

```hcl
# Managed Identity for AKS workloads
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.app_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags
}

# App Service with Key Vault references
resource "azurerm_linux_web_app" "app" {
  name                = "app-${var.app_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  service_plan_id     = azurerm_service_plan.main.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  app_settings = {
    DATABASE_URL = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_url.versionless_id})"
    WEBSITE_RUN_FROM_PACKAGE = "1"
  }

  site_config {
    always_on        = true
    application_stack {
      node_version = "20-lts"
    }
    health_check_path = "/health"
  }

  tags = local.common_tags
}

# RBAC: grant app identity read access to Key Vault
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
```

## Container Apps pattern

```hcl
resource "azurerm_container_app" "api" {
  name                         = "ca-${var.app_name}-${var.environment}"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  template {
    min_replicas = 1
    max_replicas = 10

    container {
      name   = "api"
      image  = "${azurerm_container_registry.main.login_server}/${var.image_name}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
    }

    http_scale_rule {
      name                = "http-scale"
      concurrent_requests = 100
    }
  }

  secret {
    name                = "database-url"
    key_vault_secret_id = azurerm_key_vault_secret.db_url.versionless_id
    identity            = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}
```

## Azure CLI — daily commands

```bash
# Login and set subscription
az login
az account set --subscription "My Subscription"

# Create resource group
az group create --name rg-myapp-prod --location eastus

# Deploy Bicep template
az deployment group create \
  --resource-group rg-myapp-prod \
  --template-file main.bicep \
  --parameters environment=prod

# Get Key Vault secret
az keyvault secret show --vault-name kv-myapp-prod --name db-url --query value -o tsv

# ACR push
az acr login --name myacr
docker tag myapp myacr.azurecr.io/myapp:latest
docker push myacr.azurecr.io/myapp:latest

# Force Container App revision
az containerapp update --name ca-myapp-prod --resource-group rg-myapp-prod \
  --image myacr.azurecr.io/myapp:v1.2.3

# Tail App Service logs
az webapp log tail --name app-myapp-prod --resource-group rg-myapp-prod

# AKS credentials
az aks get-credentials --resource-group rg-myapp-prod --name aks-myapp-prod

# Assign role
az role assignment create \
  --assignee <principal-id> \
  --role "Storage Blob Data Reader" \
  --scope /subscriptions/<sub>/resourceGroups/rg-myapp-prod/providers/Microsoft.Storage/storageAccounts/stmyapp
```

## GitHub Actions — Workload Identity Federation

```yaml
permissions:
  id-token: write
  contents: read

- name: Azure login
  uses: azure/login@v2
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
    # No client secret — OIDC federation
```

Federated credential config (in Entra portal or Terraform):
```hcl
resource "azurerm_federated_identity_credential" "github" {
  name                = "github-actions"
  resource_group_name = azurerm_resource_group.identity.name
  parent_id           = azurerm_user_assigned_identity.github_actions.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:myorg/myrepo:ref:refs/heads/main"
}
```

## Verification checklist

- [ ] All service authentication via Managed Identity — no client secrets in code
- [ ] Key Vault RBAC enabled (not legacy access policies)
- [ ] App settings using `@Microsoft.KeyVault(...)` references — no plaintext secrets
- [ ] Diagnostic settings enabled → Log Analytics Workspace
- [ ] Resource locks on production resource groups (`CannotDelete`)
- [ ] Resources tagged: Environment, Project, Team, ManagedBy
- [ ] Container images pulled from private ACR (not Docker Hub)
- [ ] OIDC Workload Identity Federation in CI — no `AZURE_CLIENT_SECRET` secrets
- [ ] Network ACLs set to `Deny` on Key Vault with `AzureServices` bypass
- [ ] Soft delete enabled on Key Vault (minimum 7 days, ideally 90)
