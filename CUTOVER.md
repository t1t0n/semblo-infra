# First-time setup

Bring the whole stack up from scratch. The app code in `semblo-backend`
and `semblo-frontend` is already wired to deploy through this repo — all
that's left is to push the three repos, run `terraform apply` once, set
SSM Parameter Store values, and register GitHub secrets.

> **Pre-prod path.** This runbook assumes nothing in AWS exists yet. If
> you've previously run `terraform apply` from the old
> `semblo-backend/infra/terraform/` location, see "Previously-applied
> state" at the bottom before proceeding.

## What already happened in code

Already committed in the three repos (no push yet):

- **`semblo-infra`** — fresh extraction of `terraform/` + `deploy/`, plus
  `.github/workflows/infra.yml`, `README.md`, this file.
- **`semblo-backend`** — `infra/`, `deploy/`, and `DEPLOYMENT.md`
  removed; `ci.yml` SSM script now pulls `/opt/semblo/infra-repo` and
  scopes its compose ops to the `api` service.
- **`semblo-frontend`** — landing page + `Dockerfile` + `ci.yml` that
  pulls `infra-repo` and scopes to the `frontend` service.

## 1. Push the three repos

```bash
# semblo-infra (no remote yet)
cd /home/dato/Projects/semblo-infra
gh repo create t1t0n/semblo-infra --private --source=. --remote=origin --push

# semblo-frontend (no remote yet)
cd /home/dato/Projects/semblo-frontend
gh repo create t1t0n/semblo-frontend --private --source=. --remote=origin --push

# semblo-backend — push the cutover commit
cd /home/dato/Projects/semblo-backend
git push
```

## 2. Bootstrap the Terraform state backend

A one-time S3 bucket + DynamoDB table for state and locking. Run with
AWS credentials that have permission to create them (admin keys are
fine for bootstrap — afterwards everything goes through OIDC).

```bash
aws s3api create-bucket \
  --bucket tf-state-semblo \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning \
  --bucket tf-state-semblo \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket tf-state-semblo \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name tf-state-semblo-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1
```

## 3. Run terraform apply

```bash
cd /home/dato/Projects/semblo-infra/terraform

terraform init \
  -backend-config="bucket=tf-state-semblo-d66d8b93" \
  -backend-config="dynamodb_table=tf-state-semblo-lock"

terraform plan
# Expect ~25 adds: EC2, EIP, SG, IAM (EC2 role + app role + infra role
# + OIDC provider), Route53 (api + apex + www), 2× S3 buckets, the
# SSM parameter stubs, etc. No destroys, no in-place changes.

terraform apply
```

> If `aws_iam_openid_connect_provider.github` errors with "already
> exists", an OIDC provider for GitHub was created in this AWS account
> previously. Import it: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`, then re-apply.

## 4. Fill in SSM Parameter Store

Terraform created stub parameters with value `REPLACE_ME`. Set the real
values now — these are read by `user_data.sh` at boot to populate
`/opt/semblo/.env`.

```bash
REGION=eu-central-1

aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_JWT_SECRET \
  --value "$(openssl rand -hex 32)"

aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/POSTGRES_PASSWORD \
  --value "$(openssl rand -hex 24)"

# GitHub PAT for cloning semblo-infra onto the EC2 box (read:packages
# + repo scopes; restrict to the infra repo if using a fine-grained
# token).
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/GITHUB_TOKEN \
  --value "ghp_..."

# Compose interpolation — owner/repo for each app image on GHCR.
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/GHCR_REPOSITORY --value t1t0n/semblo-backend
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/FRONTEND_GHCR_REPOSITORY --value t1t0n/semblo-frontend

# App config — visible-ish values, kept in SSM for uniformity.
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_ENV --value prod
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_PUBLIC_BASE_URL --value https://api.semblo.app
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_CORS_ORIGINS --value https://semblo.app
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_S3_BUCKET \
  --value "$(cd /home/dato/Projects/semblo-infra/terraform && terraform output -raw uploads_bucket)"
aws ssm put-parameter --region $REGION --type SecureString --overwrite \
  --name /semblo/prod/SEMBLO_S3_REGION --value $REGION

# Optional — overwrite only if you want non-default values.
# SEMBLO_EMAIL_BACKEND, SEMBLO_EMAIL_FROM, SEMBLO_LOG_LEVEL stay as
# REPLACE_ME and the API uses compiled-in defaults from config.py.
```

If the EC2 already booted with `REPLACE_ME` values, restart it (or just
the api container) to re-read SSM:

```bash
aws ssm send-command --instance-ids $(cd terraform && terraform output -raw instance_id) \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /opt/semblo && docker compose restart api"]'
```

## 5. Register GitHub secrets + variables

Pull the values from `terraform output`:

```bash
cd /home/dato/Projects/semblo-infra/terraform

APP_ROLE=$(terraform output -raw gh_app_role_arn)
INFRA_ROLE=$(terraform output -raw gh_infra_role_arn)
EC2_ID=$(terraform output -raw instance_id)

# semblo-backend
gh secret   set AWS_OIDC_ROLE_ARN --repo t1t0n/semblo-backend  --body "$APP_ROLE"
gh variable set EC2_INSTANCE_ID   --repo t1t0n/semblo-backend  --body "$EC2_ID"

# semblo-frontend
gh secret   set AWS_OIDC_ROLE_ARN --repo t1t0n/semblo-frontend --body "$APP_ROLE"
gh variable set EC2_INSTANCE_ID   --repo t1t0n/semblo-frontend --body "$EC2_ID"

# semblo-infra (different role — admin, not SSM-only)
gh secret   set AWS_OIDC_ROLE_ARN --repo t1t0n/semblo-infra    --body "$INFRA_ROLE"
gh variable set EC2_INSTANCE_ID   --repo t1t0n/semblo-infra    --body "$EC2_ID"
```

## 6. Trigger the first deploys

```bash
# Backend image → GHCR → SSM restart of api
gh workflow run --repo t1t0n/semblo-backend  CI

# Frontend image → GHCR → SSM restart of frontend
gh workflow run --repo t1t0n/semblo-frontend CI
```

(Or just push an empty commit to `main` in each repo.)

## 7. Smoke test

```bash
curl -fsS https://api.semblo.app/healthz
curl -fsS https://semblo.app/healthz
curl -fsSI https://www.semblo.app | head -3   # 301 → https://semblo.app
```

If Caddy is still issuing certs, give it ~60s on first hit. Caddy logs
live at `docker logs semblo-caddy` (via `aws ssm start-session`).

---

## Previously-applied state

If `terraform apply` was already run from the old
`semblo-backend/infra/terraform/` location and you don't want to throw
away the EC2 / EIP / IAM / DNS records:

1. **Don't run the bootstrap commands in step 2** — the bucket + table already exist.
2. After `terraform init` in step 3, run `terraform plan` and read carefully:
   - The 5 new resources (apex + www DNS, new infra OIDC role + attachment, two new SSM params) should show as adds.
   - The existing app-role trust will show an in-place change (single repo → list of two).
   - The EC2's `user_data` hash changes (different `infra_repo` clone), but `user_data_replace_on_change = false` keeps the instance — confirm Terraform reports "1 to change" on `aws_instance.api`, not "1 to destroy + 1 to add".
3. After `terraform apply`, you still need step 4 (the new SSM params) and step 5 (re-register secrets — the role ARNs are unchanged but the infra role is new).
4. On the EC2, the symlinks still point at the old backend clone. Open an SSM session and re-point them:
   ```bash
   sudo -i
   cd /opt/semblo
   GITHUB_TOKEN=$(aws --region eu-central-1 ssm get-parameter \
     --name /semblo/prod/GITHUB_TOKEN --with-decryption \
     --query 'Parameter.Value' --output text)
   git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/t1t0n/semblo-infra.git" infra-repo
   ln -sf /opt/semblo/infra-repo/deploy/compose.prod.yml /opt/semblo/compose.prod.yml
   ln -sf /opt/semblo/infra-repo/deploy/Caddyfile        /opt/semblo/Caddyfile
   docker compose -f compose.prod.yml pull
   docker compose -f compose.prod.yml up -d
   rm -rf repo   # old backend clone, no longer used
   ```
