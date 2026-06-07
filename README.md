# semblo-infra

Shared infrastructure for the Semblo stack: AWS provisioning (Terraform),
host-level Docker Compose, Caddy config, and EC2 cloud-init. App code
lives in [`semblo-backend`](https://github.com/t1t0n/semblo-backend),
[`semblo-frontend`](https://github.com/t1t0n/semblo-frontend) (marketing
site, apex) and [`semblo-web`](https://github.com/t1t0n/semblo-web)
(authenticated web app, `web.semblo.app`).

```
.
├── terraform/        # AWS: EC2, IAM (OIDC for the app repos + this one),
│                       Route53 (api + apex + www + web app), S3 (uploads + backups),
│                       SSM Parameter Store.
├── deploy/           # Files that get rsynced/symlinked onto the EC2 box.
│   ├── compose.prod.yml
│   ├── Caddyfile
│   └── user_data.sh
└── .github/workflows/
    └── infra.yml     # tf fmt/init/validate/plan on PRs; apply + SSM rollout on main.
```

## Who deploys what

| Repo              | What it ships                          | Role assumed                          |
| ----------------- | -------------------------------------- | ------------------------------------- |
| `semblo-backend`  | API Docker image → GHCR → SSM restart  | `semblo-prod-gh-actions` (SSM-only)   |
| `semblo-frontend` | Marketing site → GHCR → SSM restart (apex `semblo.app`) | `semblo-prod-gh-actions` (SSM-only) |
| `semblo-web`      | Web app → GHCR → SSM restart (`web.semblo.app`)         | `semblo-prod-gh-actions` (SSM-only) |
| `semblo-infra`    | Terraform apply + compose/Caddy rollout| `semblo-prod-gh-infra` (Admin)        |

## Terraform state

S3 backend: `s3://tf-state-semblo/semblo/prod/terraform.tfstate` (eu-central-1),
locking via DynamoDB table `tf-state-semblo-lock`. Local init:

```bash
cd terraform
terraform init \
  -backend-config="bucket=tf-state-semblo" \
  -backend-config="dynamodb_table=tf-state-semblo-lock"
```

## First-time setup

See [`CUTOVER.md`](./CUTOVER.md) for migrating from the previous layout
where Terraform + deploy files lived inside `semblo-backend`.
