---
skill: apex-gcp
version: 1.0.0
last_updated: 2026-05-28
sources:
  - GCP Architecture Framework — cloud.google.com/architecture/framework
  - Google Cloud Docs — cloud.google.com/docs
  - Terraform Google Provider — registry.terraform.io/providers/hashicorp/google
staleness_threshold: 14d
---

# GCP Cloud Architect — Planning Mode

## When to activate
Any spec involving Google Cloud infrastructure, BigQuery/analytics, Vertex AI, GKE,
Cloud Run, IaC on GCP, organisation setup, IAM/Workload Identity Federation, or cost optimisation.

## Questions to ask before designing

- Data/AI-heavy workload? (GCP has native BigQuery + Vertex AI advantage)
- Kubernetes expertise available? (GKE Standard vs GKE Autopilot)
- Multi-cloud or GCP-only? (Terraform either way — Cloud Deployment Manager is legacy)
- What is the org size? (single project vs Organisation + Folder hierarchy)
- HTTP microservices or event-driven functions? (Cloud Run vs Cloud Run Functions)
- Existing BigQuery / GCP data estate to build on?

## Architecture Framework — 6 pillars

| Pillar | Core focus |
|--------|-----------|
| System Design | Loose coupling, API-first, managed services over self-managed |
| Operational Excellence | IaC mandatory, SRE practices, blameless post-mortems |
| Reliability | SLOs/SLIs, multi-zone/multi-region, chaos testing, health checks |
| Security, Privacy & Compliance | IAM least privilege, VPC Service Controls, DLP, Assured Workloads |
| Cost Optimization | CUDs, Spot VMs, GKE Autopilot, right-sizing |
| Performance Optimization | Right machine type, Global Load Balancing, GKE Autopilot bin packing |

## Compute selection

| Pattern | Service | When |
|---------|---------|------|
| HTTP services, scales to zero | **Cloud Run** | Serverless containers; no k8s needed |
| Event-driven functions | **Cloud Run Functions** | Pub/Sub triggers, HTTP, short tasks |
| Kubernetes, no node ops | **GKE Autopilot** | Per-pod billing, fully managed — preferred |
| Kubernetes, full control | **GKE Standard** | DaemonSets, custom node configs, GPU |
| Lift-and-shift / GPU | Compute Engine | Legacy, ML training, custom OS |

GKE Autopilot is the default choice for new containerised workloads — eliminates idle node cost.

```bash
# Create Autopilot cluster
gcloud container clusters create-auto my-cluster \
  --region us-central1 \
  --project my-project-id
```

## IaC: Terraform is the standard

**Cloud Deployment Manager is legacy — never use for new work.**
Google's own blueprints and Cloud Foundation Toolkit (CFT) all use Terraform.

```hcl
provider "google" {
  project = var.project_id
  region  = "us-central1"
}

resource "google_cloud_run_v2_service" "app" {
  name     = "my-service"
  location = "us-central1"
  template {
    containers {
      image = "gcr.io/${var.project_id}/app:latest"
    }
    service_account = google_service_account.app.email
  }
}
```

**State backend:** GCS bucket with versioning enabled. Use Workload Identity Federation for CI/CD — no service account key files.

## Key services reference

**Data / Analytics:**
| Service | Use case |
|---------|---------|
| BigQuery | Serverless SQL analytics; petabyte-scale; built-in ML (BQML) |
| Cloud SQL | Managed MySQL / PostgreSQL / SQL Server |
| Cloud Spanner | Global, strongly consistent, horizontally scalable SQL (expensive; ~$0.90/node/hr) |
| Firestore | Serverless document DB with real-time sync |
| Bigtable | Sub-10ms wide-column; IoT / time-series at massive scale |
| Pub/Sub | Global messaging: at-least-once, push/pull, Dataflow integration |

**BigQuery best practices:** Partition tables by date, cluster by common filter columns, use `INFORMATION_SCHEMA` for cost tracking. On-demand pricing: pay per TB scanned — column pruning saves money.

**AI/ML:**
- **Vertex AI**: training, serving, pipelines, Model Garden (Gemini, Llama, Claude)
- **BigQuery ML**: train + serve ML models via SQL — no separate infra

## Identity: IAM + Workload Identity

**GCP IAM model:** deny-by-default, additive roles. Assign at the most granular scope (resource > project > folder > org).

| Practice | Implementation |
|----------|---------------|
| No service account key files | **Workload Identity Federation** — maps GitHub Actions / AWS roles to GCP SAs |
| Pod-level identity on GKE | **GKE Workload Identity** — K8s Service Account → Google Service Account |
| Least privilege | Use predefined roles; never assign `Editor` or `Owner` to service accounts |
| Human access | Google Workspace / Cloud Identity SSO; short-lived tokens only |

```bash
# Bind GKE workload identity
gcloud iam service-accounts add-iam-policy-binding \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:PROJECT.svc.id.goog[NAMESPACE/KSA_NAME]" \
  GSA_NAME@PROJECT.iam.gserviceaccount.com
```

## Organisation structure

```
Organisation (company.com)
├── Folders (by env: prod/dev/staging; or by BU)
│   └── Projects (billing + IAM boundary — one per app/env)
│       └── Resources (VMs, Cloud Run, GCS, etc.)
```

**GCP VPC is global** — one VPC spans all regions (unlike AWS/Azure regional VPCs).
**Shared VPC:** host project owns the VPC; service projects attach — centralised firewall rules.

**Key org policies to enforce:**
- `iam.allowedPolicyMemberDomains` — block personal Gmail accounts
- `compute.vmExternalIpAccess` — deny external IPs on VMs (use Cloud NAT)
- `compute.requireShieldedVm` — enforce Shielded VM
- `storage.uniformBucketLevelAccess` — disable legacy ACLs on GCS

## Cost optimisation

| Mechanism | Saving | Notes |
|-----------|--------|-------|
| Committed Use Discounts (CUD) | 55–70% | 1 or 3 year; resource-based or flexible |
| Spot VMs / Preemptible | Up to 91% | 30-second eviction warning; fault-tolerant only |
| Sustained Use Discounts (SUD) | Up to 30% | Automatic — VM runs >25% of month |
| GKE Autopilot | Indirect | Per-pod billing eliminates wasted node capacity |

**Cloud Run scales to zero** — no cost when idle.
**BigQuery:** Use flat-rate / capacity commitments for high-query-volume orgs.

## Security baseline

```
[ ] Service accounts use minimum required roles — no Editor/Owner
[ ] Workload Identity Federation for CI/CD (no key file downloads)
[ ] GKE Workload Identity for pod-level identity
[ ] Org policy: iam.allowedPolicyMemberDomains — block personal accounts
[ ] VPC Service Controls perimeter around sensitive projects (BigQuery, GCS with PII)
[ ] Cloud Audit Logs at org level (Admin Activity + Data Read/Write)
[ ] No external IPs on VMs (org policy deny + Cloud NAT for egress)
[ ] GCS uniform bucket-level access enabled
[ ] Secret Manager for all secrets — not environment variables
[ ] Security Command Center (SCC) enabled for threat detection
[ ] CMEK via Cloud KMS for BigQuery/GCS/Spanner with sensitive data
```

## Review checklist

- [ ] IaC: Terraform (not Cloud Deployment Manager)
- [ ] Service accounts have minimum roles — no Editor/Owner
- [ ] Workload Identity Federation configured for CI/CD
- [ ] GKE Autopilot preferred over GKE Standard unless DaemonSets/custom nodes needed
- [ ] Cloud Run scales to zero for HTTP services
- [ ] Org policies enforced (no external IPs, domain-restricted IAM, shielded VMs)
- [ ] BigQuery tables partitioned and clustered
- [ ] Secret Manager used — no hardcoded secrets or env var secrets
- [ ] All resources labelled: environment, team, managed-by

## Standards

GCP Architecture Framework: cloud.google.com/architecture/framework
Cloud Foundation Toolkit: github.com/GoogleCloudPlatform/cloud-foundation-toolkit
GCP IAM Best Practices: cloud.google.com/iam/docs/using-iam-securely
