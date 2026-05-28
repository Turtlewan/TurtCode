---
skill: apex-gcp
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# GCP — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Use `roles/owner` or `roles/editor` on service accounts — use predefined or custom roles
- Create service account keys (JSON) — use Workload Identity Federation or ADC instead
- Expose Cloud Run services publicly without authentication unless explicitly a public API
- Use the default Compute Engine service account for application workloads
- Skip `prevent_destroy = true` on Cloud SQL instances in production
- Store secrets in Terraform `.tfvars` — use Secret Manager

ALWAYS:
- Assign service accounts at the resource level, not the project level where possible
- Enable VPC Service Controls for sensitive data projects
- Use `google_project_iam_member` (additive) not `google_project_iam_binding` (authoritative, destructive)
- Tag resources with labels: `env`, `team`, `managed-by`
- Enable audit logs for Admin Activity and Data Access on sensitive APIs

## Cloud Run — Terraform pattern

```hcl
# Service account per Cloud Run service
resource "google_service_account" "api" {
  account_id   = "${var.service_name}-sa"
  display_name = "${var.service_name} service account"
  project      = var.project_id
}

resource "google_cloud_run_v2_service" "api" {
  name     = var.service_name
  location = var.region
  project  = var.project_id

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 1
      max_instance_count = 10
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo}/${var.service_name}:${var.image_tag}"

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true   # only bill when processing requests
        startup_cpu_boost = true   # extra CPU during cold start
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_url.secret_id
            version = "latest"
          }
        }
      }

      liveness_probe {
        http_get { path = "/health/live" }
        initial_delay_seconds = 10
        period_seconds        = 10
      }

      startup_probe {
        http_get { path = "/health/live" }
        failure_threshold = 30
        period_seconds    = 10
      }
    }
  }

  labels = local.common_labels
}

# Grant service account Secret Manager access
resource "google_secret_manager_secret_iam_member" "api_db" {
  secret_id = google_secret_manager_secret.db_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

# Public Cloud Run — allow unauthenticated
resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.public ? 1 : 0
  name     = google_cloud_run_v2_service.api.name
  location = var.region
  project  = var.project_id
  role     = "roles/run.invoker"
  member   = "allUsers"
}
```

## Secret Manager pattern

```hcl
resource "google_secret_manager_secret" "db_url" {
  secret_id = "${var.service_name}-db-url"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.common_labels
}

# Store secret value (manage value separately from infrastructure)
resource "google_secret_manager_secret_version" "db_url" {
  secret      = google_secret_manager_secret.db_url.id
  secret_data = var.database_url   # injected from TF_VAR_database_url env var
}
```

## GKE Autopilot + Workload Identity

```hcl
resource "google_container_cluster" "main" {
  name     = "gke-${var.project_id}-${var.environment}"
  location = var.region
  project  = var.project_id

  enable_autopilot = true

  # Workload Identity is always enabled in Autopilot
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  deletion_protection = true
}

# Bind Kubernetes SA to Google SA
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_sa_name}]"
}
```

Kubernetes ServiceAccount annotation:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-app
  namespace: default
  annotations:
    iam.gke.io/gcp-service-account: my-app-sa@my-project.iam.gserviceaccount.com
```

## Cloud SQL (PostgreSQL)

```hcl
resource "google_sql_database_instance" "main" {
  name             = "${var.project_name}-${var.environment}"
  database_version = "POSTGRES_16"
  region           = var.region
  project          = var.project_id

  settings {
    tier              = "db-g1-small"
    availability_type = var.environment == "prod" ? "REGIONAL" : "ZONAL"

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main.id
    }

    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
  }

  deletion_protection = true
}
```

## gcloud CLI — daily commands

```bash
# Set project and region defaults
gcloud config set project my-project-id
gcloud config set run/region us-central1

# Artifact Registry — push image
gcloud auth configure-docker us-central1-docker.pkg.dev
docker build -t us-central1-docker.pkg.dev/my-project/my-repo/myapp:latest .
docker push us-central1-docker.pkg.dev/my-project/my-repo/myapp:latest

# Deploy Cloud Run service
gcloud run deploy my-service \
  --image us-central1-docker.pkg.dev/my-project/my-repo/myapp:latest \
  --region us-central1 \
  --service-account my-service-sa@my-project.iam.gserviceaccount.com

# Tail Cloud Run logs
gcloud run services logs tail my-service --region us-central1

# Access secret
gcloud secrets versions access latest --secret my-service-db-url

# GKE credentials
gcloud container clusters get-credentials gke-my-project-prod --region us-central1

# Cloud SQL proxy (for local dev)
cloud-sql-proxy my-project:us-central1:my-instance

# Impersonate service account locally
gcloud auth application-default login --impersonate-service-account=my-sa@my-project.iam.gserviceaccount.com
```

## GitHub Actions — Workload Identity Federation

```yaml
permissions:
  id-token: write
  contents: read

- name: Authenticate to Google Cloud
  uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/123456789/locations/global/workloadIdentityPools/github/providers/github
    service_account: github-actions@my-project.iam.gserviceaccount.com

- name: Set up Cloud SDK
  uses: google-github-actions/setup-gcloud@v2
```

Terraform for the WIF pool:
```hcl
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  project                            = var.project_id
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }
  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
  attribute_condition = "assertion.repository == 'myorg/myrepo'"
}
```

## Verification checklist

- [ ] No service account keys created — Workload Identity or ADC used
- [ ] Service accounts scoped to minimum required IAM roles
- [ ] `google_project_iam_member` used (additive) not `google_project_iam_binding`
- [ ] Secrets in Secret Manager — not in Terraform state or env vars
- [ ] Cloud Run services use private Cloud SQL via Private IP (not public IP)
- [ ] GKE Workload Identity configured (K8s SA annotated)
- [ ] Cloud SQL `deletion_protection = true` in production
- [ ] Audit logs enabled for Admin Activity and Data Access
- [ ] Resources labeled: env, team, managed-by
- [ ] Workload Identity Federation in CI — no JSON service account key files
