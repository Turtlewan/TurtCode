---
skill: apex-iac
backend: deepseek
version: 1.2.0
last_updated: 2026-06-10
sources:
  - OpenTofu — opentofu.org
  - Terraform — developer.hashicorp.com/terraform
  - Pulumi — pulumi.com/docs
staleness_threshold: 14d
description: >
  Coding-mode enforcement for IaC — HCL module structure, remote state + locking,
  for_each over count, prevent_destroy, no-secrets-in-state, plan-on-PR CI. HCL examples
  run on both Terraform and OpenTofu (`tofu` is drop-in) — see § Tool note. Loads when
  writing IaC.
---

# Infrastructure as Code — Coding Patterns

## Tool note (Terraform / OpenTofu)

All HCL below runs on **both** — `tofu` is a drop-in for `terraform` (same providers/modules).
**Prefer OpenTofu for new projects** (OSI licence + native state encryption); in CI use
`opentofu/setup-opentofu` instead of `hashicorp/setup-terraform`. **Pin ALL CI actions
(including first-party `actions/*`) to a full commit SHA with a version comment** — see
§ GitHub Actions below. Pulumi/Ansible patterns are tool-specific and shown separately.

## NEVER / ALWAYS

NEVER:
- Commit secrets to `.tfvars` files — use env vars (`TF_VAR_secret`) or Vault/Secrets Manager
- **Output a secret** (`output`/exported value) — it lands in **plaintext in state**; write it to a secrets manager at apply, fetch at runtime
- Run `terraform apply` without a saved plan (`terraform plan -out=tfplan` first)
- Use `terraform destroy` in production without explicit confirmation workflow
- Use `terraform workspace` for prod/staging differentiation in critical infra — use separate directories
- Mix IaC tools for the same resource set — split-brain state is dangerous
- Use `count` for resources that may be deleted from the middle of a list — use `for_each` with a map

ALWAYS:
- Configure remote state backend before any other work
- Enable state locking (DynamoDB for S3 backend, always on Terraform Cloud)
- Use `prevent_destroy = true` on critical resources (databases, state buckets)
- Run `terraform fmt -recursive` and `terraform validate` before committing
- Use `for_each` over `count` for resources that could be reordered
- Pin provider versions with `~>` constraints (e.g. `~> 5.0`)

## Module structure

```
infrastructure/
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── rds/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── ecs-service/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── environments/
    ├── dev/
    │   ├── main.tf         # calls modules
    │   ├── variables.tf
    │   ├── outputs.tf
    │   ├── terraform.tfvars
    │   └── backend.tf
    ├── staging/
    │   └── ...
    └── prod/
        └── ...
```

## Remote state backend + providers

```hcl
# backend.tf
terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "myorg-terraform-state"
    key            = "prod/main/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# main.tf — data sources, never hardcode
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    Team        = var.team
    ManagedBy   = "terraform"
  }
}
```

## Variables — best practices

```hcl
# variables.tf
variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

# Sensitive variable — never output, never log
variable "db_password" {
  type      = string
  sensitive = true
}
```

## for_each over count

```hcl
# ✅ for_each — safe to add/remove items
variable "environments" {
  type    = set(string)
  default = ["dev", "staging", "prod"]
}

resource "aws_s3_bucket" "env_buckets" {
  for_each = var.environments
  bucket   = "${var.project}-${each.key}-artifacts"
  tags     = merge(local.common_tags, { Environment = each.key })
}

# ✅ for_each with map — key is stable identifier
resource "aws_iam_user" "service_accounts" {
  for_each = {
    deploy    = "CI/CD deployment user"
    readonly  = "Read-only auditor"
  }
  name = "${var.project}-${each.key}"
  tags = merge(local.common_tags, { Purpose = each.value })
}
```

## prevent_destroy on critical resources

```hcl
resource "aws_db_instance" "main" {
  identifier     = "${var.project}-${var.environment}"
  engine         = "postgres"
  engine_version = "16.2"
  instance_class = "db.t3.micro"
  # ... other config

  lifecycle {
    prevent_destroy = true   # Terraform error if you try to destroy
    ignore_changes  = [engine_version]  # allow minor version upgrades
  }
}
```

## Pulumi TypeScript pattern

```typescript
import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";

const config = new pulumi.Config();
const environment = config.require("environment");

const commonTags = {
  Environment: environment,
  Project: "myapp",
  ManagedBy: "pulumi",
};

// VPC
const vpc = new aws.ec2.Vpc("main", {
  cidrBlock: "10.0.0.0/16",
  enableDnsHostnames: true,
  tags: { ...commonTags, Name: `myapp-${environment}-vpc` },
});

// Secret — not in code, from config
const dbPassword = config.requireSecret("dbPassword");

// RDS
const db = new aws.rds.Instance("main", {
  engine: "postgres",
  engineVersion: "16.2",
  instanceClass: "db.t3.micro",
  dbName: "myapp",
  username: "myapp",
  password: dbPassword,
  skipFinalSnapshot: environment !== "prod",
  tags: commonTags,
});

export const dbEndpoint = db.endpoint;
```

## Terraform commands

```bash
# Standard workflow
terraform init                          # init providers + backend
terraform fmt -recursive                # format all .tf files
terraform validate                      # check syntax and logic
terraform plan -out=tfplan              # create plan artifact
terraform show tfplan                   # review the plan
terraform apply tfplan                  # apply (no interactive prompt)

# Import existing resource
terraform import aws_s3_bucket.data my-existing-bucket

# State operations
terraform state list                    # list all managed resources
terraform state show aws_vpc.main       # show state for a resource
terraform state mv old_name new_name    # rename (no destroy/recreate)
terraform state rm aws_resource.name    # remove from state (resource remains in cloud)

# Targeted operations (use sparingly)
terraform plan -target=module.vpc
terraform apply -target=aws_db_instance.main

# Workspace operations (ephemeral envs only)
terraform workspace new feature-xyz
terraform workspace select feature-xyz
terraform workspace delete feature-xyz

# Cost estimation
infracost breakdown --path .
infracost diff --path . --compare-to infracost-base.json --format json
```

## Ansible — idempotent task patterns

```yaml
# roles/app/tasks/main.yml
---
- name: Install Node.js
  ansible.builtin.package:
    name: "nodejs"
    state: present
  become: yes

- name: Create app user
  ansible.builtin.user:
    name: appuser
    shell: /bin/bash
    system: yes
    create_home: yes

- name: Deploy app config
  ansible.builtin.template:
    src: app.env.j2
    dest: /etc/myapp/app.env
    owner: appuser
    group: appuser
    mode: "0600"
  notify: Restart app   # triggers handler only if file changes

- name: Start and enable app service
  ansible.builtin.systemd:
    name: myapp
    state: started
    enabled: yes
    daemon_reload: yes
```

```bash
# Ansible commands
ansible-playbook site.yml -i inventory/prod         # run playbook
ansible-playbook site.yml -i inventory/prod --check  # dry run
ansible-playbook site.yml -i inventory/prod --diff   # show file diffs
ansible-lint site.yml                                 # lint
ansible-playbook site.yml --tags "nginx,ssl"         # run specific tags
ansible all -i inventory/prod -m ping                # check connectivity
```

## GitHub Actions — plan on PR, apply on merge (canonical, OpenTofu)

The plan is saved as `tfplan` in the plan job and passed to the apply job as an artifact —
apply runs exactly what was planned. All actions SHA-pinned with a version comment.
Note: a saved plan can contain secret values — keep artifact retention short (1 day).

```yaml
name: IaC
on:
  pull_request:
    paths: ["infrastructure/**"]
  push:
    branches: [main]
    paths: ["infrastructure/**"]

permissions:
  contents: read              # least privilege at workflow level

jobs:
  plan:
    runs-on: ubuntu-latest
    permissions:
      id-token: write         # OIDC — no access keys
      contents: read
    defaults:
      run:
        working-directory: infrastructure/environments/prod
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: opentofu/setup-opentofu@592200bd4b9bbf4772ace78f887668b1aee8f716 # v1.0.5
        with:
          tofu_version: "~1.9"
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@ececac1a45f3b08a01d2dd070d28d111c5fe6722 # v4.1.0
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE }}
          aws-region: us-east-1
      - run: tofu init
      - run: tofu fmt -check -recursive
      - run: tofu validate
      - run: tofu plan -out=tfplan
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4.6.2
        with:
          name: tfplan
          path: infrastructure/environments/prod/tfplan
          retention-days: 1

  apply:
    needs: plan
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    environment: production   # requires approval in GitHub Environments
    permissions:
      id-token: write         # OIDC — no access keys
      contents: read
    defaults:
      run:
        working-directory: infrastructure/environments/prod
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - uses: opentofu/setup-opentofu@592200bd4b9bbf4772ace78f887668b1aee8f716 # v1.0.5
        with:
          tofu_version: "~1.9"
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@ececac1a45f3b08a01d2dd070d28d111c5fe6722 # v4.1.0
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE }}
          aws-region: us-east-1
      - uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093 # v4.3.0
        with:
          name: tfplan
          path: infrastructure/environments/prod
      - run: tofu init
      - run: tofu apply tfplan
```

## Verification checklist

- [ ] Remote backend configured with state locking
- [ ] Provider versions pinned with `~>` constraints
- [ ] `terraform fmt` and `terraform validate` pass
- [ ] `for_each` used instead of `count` for resources that may change membership
- [ ] `prevent_destroy = true` on databases, state buckets, critical resources
- [ ] Sensitive variables marked `sensitive = true`
- [ ] No secrets in `.tfvars` files committed to git
- [ ] Resources tagged: Environment, Project, Team, ManagedBy
- [ ] Infracost or equivalent running on PRs
- [ ] CI: plan on PR, apply only on merge to main
- [ ] Ansible tasks are idempotent (pass `--check` without errors)
