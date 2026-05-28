---
skill: apex-iac
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Terraform Docs — developer.hashicorp.com/terraform
  - Pulumi Docs — pulumi.com/docs
  - Ansible Docs — docs.ansible.com
staleness_threshold: 14d
---

# Infrastructure as Code Specialist — Planning Mode

## When to activate
Any spec involving Terraform, Pulumi, Ansible, AWS CDK, or any IaC tooling.
Distinct from apex-devops (CI/CD pipelines) — this skill covers declarative resource
provisioning, state management, module design, drift detection, and IaC best practices.

## Questions to ask before designing

- Single cloud or multi-cloud? (determines tool choice)
- Team background: developers or ops? (CDK/Pulumi vs Terraform/HCL)
- Existing IaC estate? (match the existing tool to avoid split-brain)
- How is state stored and shared across the team? (remote backend required)
- What environments exist? (dev/staging/prod — workspace strategy)
- Are there compliance requirements for drift detection or change auditing?

## Tool selection

| Situation | Tool | Rationale |
|-----------|------|-----------|
| Multi-cloud, ops team | **Terraform** | HCL is readable, large module ecosystem, mature state management |
| AWS-only, developer team | **AWS CDK v2** | TypeScript/Python, compiles to CloudFormation, high-level constructs |
| Multi-cloud, developer team | **Pulumi** | Real languages (TS/Python/Go), same power as Terraform |
| Configuration management (OS-level) | **Ansible** | Agentless, YAML playbooks, idempotent SSH-based operations |
| GCP-specific | **Terraform + google provider** | Google's own blueprints use Terraform; CFT modules available |
| Serverless AWS | **AWS SAM** | Lambda-optimised, built on CloudFormation |

**Never mix tools for the same resources** — split-brain state causes drift and conflicts.

## Terraform: core workflow and patterns

```hcl
# ── Module structure ──────────────────────────────────────
modules/
  vpc/          main.tf, variables.tf, outputs.tf
  rds/          main.tf, variables.tf, outputs.tf
  ecs-service/  main.tf, variables.tf, outputs.tf

environments/
  dev/          main.tf (calls modules), terraform.tfvars
  staging/      main.tf, terraform.tfvars
  prod/         main.tf, terraform.tfvars
```

```hcl
# ── Remote state backend (S3 + DynamoDB lock) ─────────────
terraform {
  backend "s3" {
    bucket         = "myorg-terraform-state"
    key            = "prod/vpc/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# ── Variables — never hardcode ────────────────────────────
variable "environment" {
  type    = string
  description = "Deployment environment: dev, staging, prod"
}

# ── Tag everything ────────────────────────────────────────
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "terraform"
    Team        = var.team
  }
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags       = merge(local.common_tags, { Name = "${var.project}-vpc" })
}
```

```bash
# Workflow
terraform init                    # download providers, configure backend
terraform plan -out=tfplan         # show changes, save plan
terraform apply tfplan             # apply saved plan (no interactive prompt)
terraform destroy                  # tear down (always review plan first)

# Format and validate
terraform fmt -recursive
terraform validate

# State operations (with care)
terraform state list
terraform state show aws_vpc.main
terraform import aws_vpc.main vpc-abc123   # import existing resource
```

**Secrets:** Never in `.tfvars` committed to git. Use Vault dynamic secrets, AWS Secrets Manager, or environment variables (`TF_VAR_secret_name`).

## Workspaces vs directories

**Workspaces** (same config, different state): suitable for identical environments with minor variable differences.
**Separate directories** (different configs): recommended for environments with different architectures, or where drift between environments is intentional. More explicit, easier to audit.

**Recommendation:** Use separate directories for dev/staging/prod. Use workspaces only for ephemeral feature environments.

## Drift detection and compliance

```bash
# Detect drift: what changed outside Terraform?
terraform plan  # shows diff between state and real infrastructure

# AWS Config: continuous drift detection (works alongside Terraform)
# Alerts when resources deviate from last known CloudFormation/Terraform state
```

**Cost estimation:** Infracost — run in CI to estimate cost impact of every PR:
```bash
infracost breakdown --path .
infracost diff --path . --compare-to infracost-base.json
```

## Pulumi patterns

```typescript
// TypeScript — same expressiveness as application code
import * as aws from "@pulumi/aws";

const bucket = new aws.s3.BucketV2("my-bucket", {
  tags: { Environment: "production", ManagedBy: "pulumi" }
});

const policy = new aws.s3.BucketPolicy("my-bucket-policy", {
  bucket: bucket.id,
  policy: bucket.id.apply(id => JSON.stringify({
    Statement: [{ Effect: "Allow", Principal: "*", Action: "s3:GetObject", Resource: `arn:aws:s3:::${id}/*` }]
  }))
});

export const bucketName = bucket.id;
```

```bash
pulumi up      # preview + apply
pulumi preview # plan only (no apply)
pulumi destroy # tear down
pulumi stack   # manage environments as stacks
```

## Ansible patterns

Use Ansible for: OS-level configuration, software installation, user management, post-provisioning setup that Terraform doesn't cover.

```yaml
# site.yml
---
- name: Configure web servers
  hosts: webservers
  become: yes
  roles:
    - common
    - nginx
    - app

# roles/nginx/tasks/main.yml
- name: Install nginx
  ansible.builtin.package:
    name: nginx
    state: present

- name: Configure nginx
  ansible.builtin.template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
  notify: Restart nginx
```

**Idempotency is mandatory:** every task must be idempotent. Test with `--check` flag first. Use `ansible-lint` in CI.

## IaC in CI/CD

```yaml
# GitHub Actions pattern
- name: Terraform Plan
  run: |
    terraform init
    terraform plan -out=tfplan
  env:
    AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}  # OIDC, no access keys

- name: Cost estimate (Infracost)
  uses: infracost/actions/setup@v3
  run: infracost diff --path . --format json --out-file /tmp/infracost.json

# Apply only on merge to main — never on PR
- name: Terraform Apply
  if: github.ref == 'refs/heads/main'
  run: terraform apply tfplan
```

## Review checklist

- [ ] Remote state backend configured (S3+DynamoDB, Terraform Cloud, GCS)
- [ ] State locking enabled
- [ ] All secrets via Vault/AWS Secrets Manager/env vars — not in `.tfvars` committed to git
- [ ] Resources tagged: Environment, Project, Team, ManagedBy=terraform
- [ ] Modules used for reusable patterns (no copy-paste resource blocks)
- [ ] `terraform fmt` and `terraform validate` pass
- [ ] CI runs `terraform plan` on PR; `apply` only on merge to main
- [ ] Drift detection in place (Config rules or scheduled plan runs)
- [ ] Infracost or equivalent for cost impact on PRs
- [ ] Destroy protection on production state (`prevent_destroy = true` on critical resources)

## Standards

Terraform: developer.hashicorp.com/terraform
Pulumi: pulumi.com/docs
Ansible: docs.ansible.com
Infracost: infracost.io
