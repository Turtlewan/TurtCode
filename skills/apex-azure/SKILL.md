---
skill: apex-azure
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Azure Well-Architected Framework — learn.microsoft.com/azure/well-architected
  - Azure Docs — learn.microsoft.com/azure
  - Terraform AzureRM Provider — registry.terraform.io/providers/hashicorp/azurerm
staleness_threshold: 14d
---

# Azure Cloud Architect — Planning Mode

## When to activate
Any spec involving Azure infrastructure, service selection, IaC (Bicep/Terraform),
Entra ID / identity design, Landing Zone setup, AKS, cost optimisation, or Azure security posture.

## Questions to ask before designing

- Is this Azure-only or multi-cloud? (determines Bicep vs Terraform)
- Enterprise/corp network integration needed? (Hub-and-Spoke vs Virtual WAN)
- What compliance standard applies? (ISO 27001, SOC 2, PCI → affects Defender, CMK, logs)
- New greenfield or extending existing Azure estate? (Landing Zone vs ad-hoc)
- .NET / Windows workloads? (Azure SQL MI, App Service, Azure DevOps fit better)
- What is the identity source? (Entra ID native, on-prem AD sync via Entra Connect, or external IdP)

## Well-Architected Framework — 5 pillars

| Pillar | Core question | Key tools |
|--------|---------------|-----------|
| Reliability | Will it survive failures? | Zone redundancy, Availability Sets, Azure Monitor, Chaos Studio |
| Security | Zero Trust — never trust, always verify | Entra ID, PIM, Defender for Cloud, Private Endpoints |
| Cost Optimization | Pay only for what you use | Azure Cost Management, Reservations, Spot VMs, Advisor |
| Operational Excellence | Safe deployments, fast recovery | CI/CD, ARM/Bicep, structured logging with correlation IDs |
| Performance Efficiency | Scales to meet demand | AKS HPA, App Service autoscale, Azure CDN, load testing |

## Compute selection

| Pattern | Service | When |
|---------|---------|------|
| Web/API, minimal ops | App Service | PaaS, auto-scale, deployment slots for blue/green |
| Containerised, K8s control | AKS | Full Kubernetes; use Spot node pools for non-critical |
| Containerised, serverless | Azure Container Apps | No K8s expertise needed, event-driven scaling |
| Functions / event-driven | Azure Functions | Consumption plan: pay per invocation |
| Enterprise integration | Logic Apps Standard | Connector-heavy workflows (Office 365, SAP, etc.) |
| Windows/.NET legacy | Azure VMs (with Scale Sets) | Lift-and-shift |

## IaC selection

| Situation | Tool |
|-----------|------|
| Azure-only | **Bicep** — first-class Microsoft support, VS Code extension, what-if |
| Multi-cloud or existing HCL | **Terraform + AzureRM provider** |
| Never | Raw ARM JSON — it is the compilation target, not the authoring language |

**Bicep example:**
```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2025-06-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}
```

**Azure Verified Modules (AVM):** Microsoft-maintained Bicep and Terraform modules for Landing Zone components. Use before hand-rolling resources.

## Identity — Entra ID (formerly Azure AD)

| Practice | Implementation |
|----------|---------------|
| No service principal passwords | Use **Managed Identities** for all compute (App Service, Functions, AKS pods) |
| No standing privileged access | **PIM (Privileged Identity Management)** — JIT access only |
| MFA everywhere | Conditional Access policies + phishing-resistant MFA |
| Workload identity for AKS | **Entra Workload Identity** — maps K8s Service Accounts to Managed Identities |
| RBAC at right scope | Assign at Resource Group, never Subscription for app permissions |

```bash
# Assign Managed Identity to Key Vault role
az role assignment create \
  --assignee <managed-identity-principal-id> \
  --role "Key Vault Secrets User" \
  --scope <key-vault-resource-id>
```

## Database selection

```
General relational → Azure SQL (zone-redundant Business Critical for HA)
Fully managed PostgreSQL → Azure Database for PostgreSQL Flexible Server
Global, multi-model NoSQL → Cosmos DB (design partition key carefully — hot partition = unbounded cost)
In-memory cache → Azure Cache for Redis
Analytics/OLAP → Azure Synapse Analytics
```

## Security baseline

```
Identity:
- Managed Identities everywhere — no service principal passwords
- PIM for all privileged roles — no standing Owner/Contributor in production
- Conditional Access + MFA for all interactive logins

Network:
- Private Endpoints for all PaaS services (SQL, Storage, Key Vault, Service Bus)
- NSG on every subnet; Azure Firewall in hub VNet for egress inspection
- No public endpoints on storage accounts or databases in production

Data:
- Key Vault for all secrets — never in App Settings or env vars
- Key Vault soft-delete: 90-day minimum
- Customer-managed keys (CMK) for regulated data (Cosmos DB, SQL, Storage)
- TLS 1.2+ minimum on all endpoints

Detection:
- Microsoft Defender for Cloud (CSPM + Workload Protection) enabled
- Centralised Log Analytics workspace — all resources ship logs here
- Azure Sentinel for SIEM on enterprise deployments
```

## Cost optimisation

| Mechanism | Saving | Commitment |
|-----------|--------|------------|
| Azure Reservations | Up to 72% | 1 or 3 year, resource-specific |
| Azure Savings Plans | Up to 65% | 1 or 3 year, compute-flexible |
| Spot VMs | Up to 90% | None — evictable |
| Azure Hybrid Benefit | Varies | Existing Windows/SQL Server license |

**AKS cost levers:** Spot node pools + node autoprovisioning + resource requests/limits on all pods.
**Budgets:** Set alerts at Resource Group scope; action groups to auto-stop non-prod environments overnight.

## Landing Zone — when to use

Use when: multiple teams, multiple environments, or enterprise governance is needed.

```
Management Group hierarchy:
Root
├── Platform (Identity, Management, Connectivity subscriptions — central IT)
└── Landing Zones
    ├── Corp (internal apps, VNet peered to hub)
    ├── Online (internet-facing apps)
    └── Sandbox (experimentation, no connectivity)
```

**Topology:** Hub-and-Spoke (Azure Firewall or NVA in hub) for most. Virtual WAN for multi-region global routing.
**Deployment:** IaC Accelerator with Azure Verified Modules (Bicep or Terraform).

## DevOps: Azure DevOps vs GitHub Actions

- **Azure DevOps**: enterprise with existing ADO investment, complex release gates, ADO Boards for work items
- **GitHub Actions**: greenfield, GitHub repos, OIDC-based auth to Azure (no secrets required)

**Prefer OIDC-based federated credentials** over `AZURE_CREDENTIALS` JSON secret — eliminates long-lived credential management.

## Review checklist

- [ ] Managed Identities on all compute — no service principal passwords
- [ ] PIM configured for privileged roles — no standing Owner/Contributor in prod
- [ ] Conditional Access + MFA enforced for all interactive logins
- [ ] Private Endpoints for SQL, Storage, Key Vault, Service Bus
- [ ] Key Vault soft-delete enabled (90-day minimum)
- [ ] NSG on every subnet
- [ ] Microsoft Defender for Cloud enabled
- [ ] Centralised Log Analytics workspace receiving all resource logs
- [ ] All resources tagged: Environment, Project, Team, CostCenter
- [ ] Zone redundancy enabled for production App Service / AKS / SQL
- [ ] IaC tool chosen: Bicep (Azure-only) or Terraform (multi-cloud)

## Standards

Azure Well-Architected Framework: learn.microsoft.com/azure/well-architected
Azure Landing Zones: learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone
Azure Verified Modules: aka.ms/avm
