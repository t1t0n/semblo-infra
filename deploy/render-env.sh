#!/usr/bin/env bash
# Render /opt/semblo/.env from every SSM parameter under /semblo/prod/*.
#
# Single source of truth for the box's environment. Called from:
#   - deploy/user_data.sh           (first boot)
#   - semblo-infra/.github/.../infra.yml   (every infra deploy, via SSM)
#   - semblo-backend/.github/.../ci.yml    (every backend deploy, via SSM)
#
# Running it on every deploy means a change in Parameter Store reaches the
# api container on the next deploy with no manual step — SSM stays the
# single source of truth. Idempotent and cheap.
#
# Secrets only ever land in the 0600 .env file; this script never echoes a
# value, so nothing sensitive appears in CI logs.
set -euo pipefail

REGION="${1:-eu-central-1}"
ENV_FILE=/opt/semblo/.env

aws --region "$REGION" ssm get-parameters-by-path \
  --path /semblo/prod \
  --recursive \
  --with-decryption \
  --query 'Parameters[*].[Name,Value]' \
  --output text \
| awk -F'\t' '{ n = split($1, p, "/"); print p[n] "=" $2 }' \
> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "render-env: wrote $(wc -l < "$ENV_FILE") vars to $ENV_FILE"
