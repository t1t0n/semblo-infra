#!/bin/bash
# Cloud-init for the Semblo prod EC2. Runs ONCE per instance launch.
#
# What this does, in order:
#   1. install Docker + Compose v2 + git + AWS CLI
#   2. clone semblo-infra so we have deploy/compose.prod.yml + Caddyfile
#   3. write /opt/semblo/.env from SSM Parameter Store
#   4. log into GHCR
#   5. install the nightly pg_dump → S3 cron
#   6. `docker compose up -d`
#
# Updates AFTER first boot happen via GH Actions SSM:SendCommand from each
# repo's CI:
#   semblo-infra:    git -C infra-repo pull && docker compose up -d
#   semblo-backend:  git -C infra-repo pull && docker compose pull api && up -d api
#   semblo-frontend: git -C infra-repo pull && docker compose pull frontend && up -d frontend
#   semblo-web:      git -C infra-repo pull && docker compose pull web && up -d web
#
# This script is rendered by Terraform templatefile(). Bare `dollar-brace`
# substitutions are Terraform variables; a doubled dollar sign escapes one
# so the shell sees a literal `dollar` at runtime.

set -euo pipefail

exec > >(tee /var/log/semblo-userdata.log | logger -t userdata -s 2>/dev/console) 2>&1
echo "[userdata] start: $(date -Is)"

# ── Packages ─────────────────────────────────────────────────────────
dnf update -y
# Amazon Linux 2023 doesn't ship cronie by default — needed for the nightly
# pg_dump backup cron we register at the end of this script.
dnf install -y docker git cronie
systemctl enable --now docker
systemctl enable --now crond

# Docker Compose v2 plugin (AL2023 doesn't ship it pre-installed).
COMPOSE_VERSION="v2.30.0"
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-aarch64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# AL2023 already has aws CLI v2; install if a slim AMI dropped it.
command -v aws >/dev/null || dnf install -y awscli

# ── Repo clone ───────────────────────────────────────────────────────
mkdir -p /opt/semblo
cd /opt/semblo

GITHUB_TOKEN=$(aws --region "${aws_region}" ssm get-parameter \
  --name /semblo/prod/GITHUB_TOKEN \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)

# Clone the infra repo. Token-in-URL lets subsequent `git pull` from CI
# (via SSM SendCommand) authenticate without external setup. Token lives
# in /opt/semblo/infra-repo/.git/config (mode 0644, root-owned, accessible
# only via SSM since the box has no SSH). Rotate by `aws ssm put-parameter`
# then rewriting that one line.
git clone "https://x-access-token:$${GITHUB_TOKEN}@github.com/${infra_repo}.git" infra-repo

# Compose looks for `compose.prod.yml` and `Caddyfile` in /opt/semblo;
# symlinks keep the source of truth in the repo.
ln -sf /opt/semblo/infra-repo/deploy/compose.prod.yml /opt/semblo/compose.prod.yml
ln -sf /opt/semblo/infra-repo/deploy/Caddyfile /opt/semblo/Caddyfile

# ── /opt/semblo/.env from SSM ────────────────────────────────────────
# Render every /semblo/prod/* parameter into /opt/semblo/.env. The same
# script runs on every deploy (via the CI SSM commands) so Parameter Store
# changes propagate without a manual step — first boot and deploys share
# identical logic. GHCR_REPOSITORY / FRONTEND_GHCR_REPOSITORY (needed by
# compose interpolation) are picked up by the same call.
bash /opt/semblo/infra-repo/deploy/render-env.sh "${aws_region}"

# ── GHCR login (system-wide so `root` can pull on subsequent reboots) ─
echo "$$GITHUB_TOKEN" | docker login ghcr.io -u x-access-token --password-stdin

# ── Nightly backup cron ──────────────────────────────────────────────
cat > /etc/cron.d/semblo-backups <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * root docker exec semblo-db pg_dump -U semblo semblo | gzip | aws --region ${aws_region} s3 cp - s3://${backups_bucket}/\$(date +\%F).sql.gz
EOF
chmod 644 /etc/cron.d/semblo-backups

# ── Bring the stack up ───────────────────────────────────────────────
# Migrations are run as a separate ephemeral container (mirrors what CD
# does on every deploy). On first boot GHCR may not have an image yet,
# so pull/migrate/up are all failure-tolerant — the first CD run will
# redo all three.
cd /opt/semblo
docker compose -f compose.prod.yml pull || \
  echo "[userdata] image pull failed; CD will retry once GHCR has an image"
docker compose -f compose.prod.yml run --rm api alembic upgrade head || \
  echo "[userdata] migration skipped; CD will run it on first deploy"
docker compose -f compose.prod.yml up -d || \
  echo "[userdata] up -d failed; CD will start the stack on first deploy"

echo "[userdata] done: $(date -Is)"
