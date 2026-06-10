---
skill: apex-aws
backend: claude
version: 1.1.0
last_updated: 2026-06-10
sources:
  - AWS Well-Architected Framework — docs.aws.amazon.com/wellarchitected
  - AWS Docs — docs.aws.amazon.com
  - AWS CDK v2 — docs.aws.amazon.com/cdk/v2/guide
staleness_threshold: 14d
description: >
  Use when designing on AWS — IAM/account security posture, Lambda/ECS/RDS/DynamoDB/S3
  decisions, VPC layout, event-driven wiring, cost traps, multi-account structure.
  Triggers: "deploy to AWS", "Lambda", "ECS/Fargate", "RDS/Aurora/DynamoDB", "S3 bucket",
  "IAM role", "our AWS bill", "multi-account". A gotcha sheet, not a service catalogue —
  frontier-known basics (Well-Architected pillars, compute/database selection tables) are
  assumed, not restated. Not IaC tool choice or state mechanics (apex-iac), CI/CD pipelines
  (apex-devops), Kubernetes workload design (apex-k8s), or Azure/GCP.
---

# AWS Cloud Architect — Planning Mode

## When to activate
Any spec involving AWS infrastructure, cloud architecture decisions, service selection,
cost optimization, multi-account setup, or AWS security posture. IaC tool choice and
state mechanics → apex-iac.

## Gotchas — the non-obvious rules

**Compute / data:**
- **Lambda ↔ RDS: always RDS Proxy.** Each concurrent invocation opens its own DB
  connection — at scale this exhausts the connection pool without a proxy.
- **DynamoDB: design access patterns FIRST.** Schema serves queries, not normalization —
  migrating a wrong key design later means a full table rewrite.
- **Aurora Serverless v2 for unpredictable load**; plain RDS Multi-AZ for steady production.

**Security:**
- **GitHub OIDC trust policy must condition on `sub`** (e.g.
  `token.actions.githubusercontent.com:sub: "repo:myorg/myrepo:ref:refs/heads/main"`) —
  without it, *any* GitHub repo can assume the role. (Workflow snippet: impl.md § OIDC.)
- **S3 public-access block on every bucket** — all four flags; a bucket policy alone is
  not enough.
- **Root account: delete root access keys, hardware MFA.** No IAM users for humans —
  federate via IAM Identity Center; workloads get execution roles only.
- **IAM Access Analyzer generates least-privilege policies from CloudTrail** — use it
  instead of hand-guessing actions.
- Databases never in public subnets; GuardDuty + CloudTrail in **all** regions (attackers
  use the regions you forgot).

**Cost:**
- **VPC Endpoints for S3/DynamoDB** eliminate NAT Gateway data-processing charges for that
  traffic — NAT is a classic silent bill-inflator.
- Layer purchase models: Savings Plans for baseline, Spot for fault-tolerant batch/CI
  (up to 90% off), On-Demand for true spikes only. Graviton (ARM) is the cheaper default.
- Tag everything (`Environment`, `Project`, `Team`, `ManagedBy`) or Cost Explorer can't
  attribute spend.

**Async / events:**
- Every queue processing business-critical work needs a **DLQ with an alarm on depth > 0**.
- SQS is at-least-once — consumers must be idempotent (apex-system-design).

**Structure:**
- Multi-account (Control Tower) only when multiple teams/environments/compliance
  boundaries exist — a solo project doesn't need an OU tree.

## Review checklist

- [ ] No IAM users for humans — federated identity only
- [ ] All workload access via execution roles (no access keys in code)
- [ ] Databases in private subnets, never public
- [ ] GuardDuty enabled, Security Hub aggregating findings
- [ ] CloudTrail enabled all regions, logs to Log Archive account
- [ ] All resources tagged: Environment, Project, Team, ManagedBy
- [ ] Cost alerts configured (AWS Budgets with SNS notification)
- [ ] Multi-AZ for all production databases and load-balanced compute
- [ ] IaC tool chosen and documented (→ apex-iac)
- [ ] Spot Instances considered for any batch/CI/fault-tolerant workloads
- [ ] Lambda that touches RDS goes through RDS Proxy
- [ ] OIDC trust policies condition on repo + ref (`sub` claim)

## Standards

AWS Well-Architected Framework: docs.aws.amazon.com/wellarchitected/latest/framework
AWS Security Best Practices: docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
AWS CDK v2: docs.aws.amazon.com/cdk/v2/guide
