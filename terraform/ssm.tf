# SSM Parameter Store entries. Terraform reserves the names with stub
# values; the operator overwrites with real values via:
#
#   aws ssm put-parameter --name /semblo/prod/SEMBLO_JWT_SECRET \
#     --type SecureString --value "$(openssl rand -hex 32)" --overwrite
#
# `lifecycle.ignore_changes` keeps Terraform from undoing those manual
# overwrites on subsequent applies — values live entirely in SSM, never
# in tfstate.
#
# user_data.sh reads every parameter under /semblo/${env}/ at first boot
# and renders /opt/semblo/.env. After any value change, restart the api
# container via SSM:SendCommand to pick it up.

locals {
  ssm_param_names = [
    # Required — generated locally; never committed.
    "SEMBLO_JWT_SECRET",
    "GITHUB_TOKEN",
    "POSTGRES_PASSWORD",

    # Required — known at provision time but kept in SSM for uniformity.
    "SEMBLO_PUBLIC_BASE_URL",
    "SEMBLO_CORS_ORIGINS",
    "SEMBLO_S3_BUCKET",
    "SEMBLO_S3_REGION",
    "SEMBLO_ENV",

    # GHCR image-path components — used by compose ${interpolation} on the
    # EC2 box. Not secrets (just owner/repo), but kept in SSM so user_data.sh
    # has one consistent source. After `terraform apply`, set them:
    #   aws ssm put-parameter --name /semblo/prod/GHCR_REPOSITORY \
    #     --type SecureString --value t1t0n/semblo-backend --overwrite
    #   aws ssm put-parameter --name /semblo/prod/FRONTEND_GHCR_REPOSITORY \
    #     --type SecureString --value t1t0n/semblo-frontend --overwrite
    "GHCR_REPOSITORY",
    "FRONTEND_GHCR_REPOSITORY",

    # Optional — set if non-default. Leave as "REPLACE_ME" to skip; the
    # api container will fall back to compiled-in defaults from config.py.
    "SEMBLO_EMAIL_BACKEND",
    "SEMBLO_EMAIL_FROM",
    "SEMBLO_LOG_LEVEL",

    # Frontend origin embedded in password-reset / verify-email URLs
    # (https://semblo.app in prod). Falls back to config.py default if unset.
    "SEMBLO_FRONTEND_BASE_URL",

    # SMTP transport for real email delivery (Google Workspace Gmail).
    # SEMBLO_SMTP_PASSWORD is a Google App Password — keep it SecureString.
    # Only consulted when SEMBLO_EMAIL_BACKEND=smtp.
    "SEMBLO_SMTP_HOST",
    "SEMBLO_SMTP_PORT",
    "SEMBLO_SMTP_STARTTLS",
    "SEMBLO_SMTP_USERNAME",
    "SEMBLO_SMTP_PASSWORD",
  ]
}

resource "aws_ssm_parameter" "app" {
  for_each = toset(local.ssm_param_names)

  name  = "/semblo/${var.environment}/${each.key}"
  type  = "SecureString"
  value = "REPLACE_ME"

  lifecycle {
    ignore_changes = [value]
  }
}
