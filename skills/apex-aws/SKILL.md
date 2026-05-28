---
skill: apex-aws
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - AWS Well-Architected Framework — docs.aws.amazon.com/wellarchitected
  - AWS Docs — docs.aws.amazon.com
  - AWS CDK v2 — docs.aws.amazon.com/cdk/v2/guide
staleness_threshold: 14d
---

# AWS Cloud Architect — Planning Mode

## When to activate
Any spec involving AWS infrastructure, cloud architecture decisions, service selection,
IaC tooling, cost optimization, multi-account setup, or AWS security posture.

## Questions to ask before designing

- What is the expected scale and traffic pattern? (serverless vs containers vs EC2)
- Is this AWS-only or multi-cloud? (determines CDK vs Terraform)
- What are the compliance requirements? (PCI, HIPAA, SOC2 → affects encryption, logging, isolation)
- Single account or multi-account? (determines whether Control Tower is needed)
- What is the team's operational capability? (managed services vs self-managed)
- What is the cost budget and expected growth? (Reserved Instances vs Savings Plans vs Spot)

## Well-Architected Framework — 6 pillars

| Pillar | Core question | Key tools |
|--------|---------------|-----------|
| Operational Excellence | Can we deploy and recover safely? | CloudWatch, Systems Manager, CloudTrail |
| Security | Is everything protected by least privilege? | IAM, GuardDuty, Security Hub, KMS |
| Reliability | Will it stay up? | Multi-AZ, Auto Scaling, Route 53 health checks |
| Performance Efficiency | Right tool for the job? | Compute Optimizer, CloudFront, ElastiCache |
| Cost Optimization | Are we paying only for what we use? | Cost Explorer, Savings Plans, Spot |
| Sustainability | Minimise environmental impact | Graviton, managed services, right-sizing |

## Compute selection guide

| Pattern | Service | When |
|---------|---------|------|
| Event-driven, short-lived | Lambda | <15 min, variable traffic, no idle cost |
| Containerised, AWS-native | ECS Fargate | No cluster ops, tight AWS integration |
| Containerised, Kubernetes | EKS Auto Mode | K8s ecosystem, portability needed |
| Long-running, custom OS | EC2 Auto Scaling | Legacy apps, GPU, full OS control |
| Simple web app | App Runner | Minimal infra knowledge required |
| Batch / ML training | EC2 Spot + Batch | Fault-tolerant, up to 90% cost reduction |

## IaC selection

| Situation | Tool |
|-----------|------|
| AWS-only, developer team | **CDK v2** (TypeScript/Python — compiles to CloudFormation) |
| Multi-cloud or existing HCL estate | **Terraform** (AWS provider) |
| Serverless-first, Lambda-heavy | **AWS SAM** (built on CloudFormation) |
| Existing CloudFormation investment | **CloudFormation** (YAML/JSON) |

Never author raw ARM JSON or CloudFormation YAML for new work — use CDK or SAM.

## Database selection

```
Relational, moderate throughput → RDS PostgreSQL (Multi-AZ for production)
Relational, high throughput / global → Aurora (5× MySQL throughput; Global Tables)
Unpredictable / serverless → Aurora Serverless v2
Key-value, single-digit ms, any scale → DynamoDB
Sub-ms cache layer → ElastiCache (Redis/Valkey)
Analytics / OLAP → Redshift
```

DynamoDB: design access patterns FIRST. Schema serves queries, not normalization.
Lambda + RDS: always use RDS Proxy (prevents connection exhaustion at scale).

## Security baseline

```
IAM:
- No long-term human credentials → federate via IAM Identity Center
- No root access keys → delete them; hardware MFA on root account
- Workloads → execution roles only (EC2 instance profiles, Lambda roles, ECS task roles)
- Use IAM Access Analyzer to generate least-privilege policies from CloudTrail

Network:
- 3-tier VPC: public (ALB, NAT GW) → private app → private DB
- Never put databases in public subnets
- VPC Endpoints for S3 and DynamoDB (eliminates NAT Gateway charges for these)
- VPC Flow Logs enabled on all production VPCs

Detection:
- GuardDuty enabled in all regions (auto-detects crypto mining, credential compromise)
- Security Hub aggregates findings; set standard: AWS FSBP
- CloudTrail in all regions with log integrity validation → Log Archive account
```

## Cost optimisation

**Layer the three models:**
1. Savings Plans / Reserved Instances → baseline (predictable) load (up to 72% off)
2. Spot Instances → fault-tolerant batch/CI (up to 90% off)
3. On-Demand → true spikes only

**Always tag every resource:** `Environment`, `Project`, `Team`, `ManagedBy`
**Use Compute Optimizer** for right-sizing recommendations (EC2, Fargate, Lambda, EBS).
**S3 Intelligent-Tiering** for data with unknown/changing access patterns.
**VPC Endpoints** to eliminate NAT Gateway data processing charges for AWS service traffic.

## Multi-account (Control Tower)

Use when: multiple teams, environments, or compliance boundaries exist.

```
Root
├── Management Account (Control Tower only)
├── Security OU
│   ├── Log Archive Account (immutable CloudTrail + Config logs)
│   └── Audit Account (GuardDuty + Security Hub aggregation)
├── Infrastructure OU (shared networking, DNS, Transit Gateway)
└── Workloads OU
    ├── Sandbox (loose guardrails, experiment freely)
    ├── Dev / Staging
    └── Production
```

**Account Factory**: self-service account vending with pre-applied guardrails and IAM Identity Center.

## Event-driven patterns

```
Work queues:        SQS (at-least-once) or SQS FIFO (exactly-once, ordered)
Fan-out:            SNS → multiple SQS queues
Service integration: EventBridge custom bus (200+ native AWS integrations)
Real-time streams:  Kinesis Data Streams (ordered, replayable, 24h–365d retention)
Distributed workflows: Step Functions (orchestration with state, retry, saga)
```

Every queue processing business-critical work needs a Dead Letter Queue (DLQ) with an alarm on depth > 0.

## Review checklist

- [ ] No IAM users for humans — federated identity only
- [ ] All workload access via execution roles (no access keys in code)
- [ ] Databases in private subnets, never public
- [ ] GuardDuty enabled, Security Hub aggregating findings
- [ ] CloudTrail enabled all regions, logs to Log Archive account
- [ ] All resources tagged: Environment, Project, Team, ManagedBy
- [ ] Cost alerts configured (AWS Budgets with SNS notification)
- [ ] Multi-AZ for all production databases and load-balanced compute
- [ ] IaC tool chosen and documented (CDK / Terraform / SAM)
- [ ] Spot Instances considered for any batch/CI/fault-tolerant workloads

## Standards

AWS Well-Architected Framework: docs.aws.amazon.com/wellarchitected/latest/framework
AWS Security Best Practices: docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
AWS CDK v2: docs.aws.amazon.com/cdk/v2/guide
