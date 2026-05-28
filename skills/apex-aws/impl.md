---
skill: apex-aws
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# AWS — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Hardcode AWS account IDs, region strings, or ARNs in source code — use env vars or SSM Parameter Store
- Create IAM users with long-lived access keys — use IAM roles + instance profiles or OIDC federation
- Use `aws_iam_policy_document` with `"*"` resources in production policies
- Store secrets in environment variables plaintext — use Secrets Manager or Parameter Store SecureString
- Deploy Lambda with 3008 MB by default — profile first, start with 256–512 MB
- Skip VPC placement for RDS/Aurora — always in private subnets

ALWAYS:
- Tag every resource: `Environment`, `Project`, `Team`, `ManagedBy=terraform`
- Enable versioning on S3 buckets holding state or important data
- Use `aws_caller_identity` and `aws_region` data sources instead of hardcoded values
- Attach execution roles to Lambda/ECS tasks — never use default roles
- Enable CloudTrail in every account — non-negotiable for audit
- Use `aws_secretsmanager_secret_version` data source to inject secrets at deploy time

## IAM patterns

```hcl
# Lambda execution role — minimum permissions
resource "aws_iam_role" "lambda_exec" {
  name = "${var.function_name}-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ECS task role — scoped to what the task actually needs
resource "aws_iam_role_policy" "task_s3" {
  name = "s3-read"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
    }]
  })
}
```

## Lambda — CDK v2 pattern

```typescript
import { Function, Runtime, Architecture, Code } from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { Duration } from 'aws-cdk-lib';

// NodejsFunction bundles automatically (esbuild)
const fn = new NodejsFunction(this, 'Handler', {
  entry: 'src/handlers/process.ts',
  handler: 'handler',
  runtime: Runtime.NODEJS_22_X,
  architecture: Architecture.ARM_64,   // Graviton — cheaper + faster for most workloads
  memorySize: 256,
  timeout: Duration.seconds(30),
  environment: {
    TABLE_NAME: table.tableName,
  },
  bundling: {
    minify: true,
    sourceMap: true,
  },
});

table.grantReadWriteData(fn);  // CDK grants — generates least-privilege policy
```

## ECS Fargate — Terraform

```hcl
resource "aws_ecs_task_definition" "app" {
  family                   = var.service_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = var.service_name
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true
    portMappings = [{ containerPort = 3000 }]

    secrets = [{
      name      = "DATABASE_URL"
      valueFrom = aws_secretsmanager_secret.db.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "ecs"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
  }])
}
```

## S3 — secure bucket baseline

```hcl
resource "aws_s3_bucket" "data" {
  bucket = "${var.project}-${var.environment}-data"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

## DynamoDB pattern

```hcl
resource "aws_dynamodb_table" "sessions" {
  name         = "${var.project}-sessions"
  billing_mode = "PAY_PER_REQUEST"  # on-demand; switch to PROVISIONED + autoscaling at scale
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }

  server_side_encryption { enabled = true }

  tags = local.common_tags
}
```

## AWS CLI — daily commands

```bash
# Assume role for cross-account access
aws sts assume-role --role-arn arn:aws:iam::123456789012:role/deploy-role \
  --role-session-name deploy | jq '.Credentials'

# Push Docker image to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com
docker build -t myapp .
docker tag myapp:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:latest
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:latest

# Force ECS service redeployment
aws ecs update-service --cluster prod --service myapp --force-new-deployment

# Get secret value
aws secretsmanager get-secret-value --secret-id prod/myapp/db --query SecretString --output text

# Tail CloudWatch logs
aws logs tail /aws/ecs/myapp --follow

# Run SSM command on EC2 instance (no SSH needed)
aws ssm start-session --target i-1234567890abcdef0

# CDK deploy
npx cdk deploy MyStack --require-approval never
npx cdk diff   # see what will change
npx cdk synth  # emit CloudFormation template (for review)
```

## GitHub Actions — OIDC auth (no access keys)

```yaml
permissions:
  id-token: write
  contents: read

- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/github-actions-deploy
    aws-region: us-east-1
    role-session-name: GitHubActions-${{ github.run_id }}
```

Trust policy for the OIDC role:
```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
    }
  }
}
```

## Verification checklist

- [ ] `terraform plan` shows no unexpected changes
- [ ] No IAM policies with `*` resources in prod
- [ ] S3 public access block enabled on all buckets
- [ ] CloudTrail enabled in all regions
- [ ] Secrets in Secrets Manager — not in env vars or `.tfvars`
- [ ] ECS task definition has health check defined
- [ ] Lambda/ECS has execution role with only required permissions
- [ ] Resources tagged with Environment, Project, Team, ManagedBy
- [ ] No hardcoded account IDs or regions in Terraform/CDK code
- [ ] OIDC federation used in CI (no `AWS_ACCESS_KEY_ID` secrets)
