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
    #   aws ssm put-parameter --name /semblo/prod/WEB_GHCR_REPOSITORY \
    #     --type SecureString --value t1t0n/semblo-web --overwrite
    "GHCR_REPOSITORY",
    "FRONTEND_GHCR_REPOSITORY",
    "WEB_GHCR_REPOSITORY",

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

    # Push notifications (FCM) — stage 15. Off until SEMBLO_FCM_ENABLED=true.
    # SEMBLO_FCM_CREDENTIALS_JSON is the Firebase service-account key,
    # base64-encoded (so it survives SSM -> .env -> compose env_file). Set it:
    #   aws ssm put-parameter --name /semblo/prod/SEMBLO_FCM_CREDENTIALS_JSON \
    #     --type SecureString --tier Intelligent-Tiering --overwrite \
    #     --value "$(base64 -w0 serviceAccountKey.json)"
    # SEMBLO_FCM_ENABLED defaults to "false" (see ssm_param_defaults) — never
    # leave it "REPLACE_ME", which would fail bool parsing and crash boot.
    "SEMBLO_FCM_ENABLED",
    "SEMBLO_FCM_PROJECT_ID",
    "SEMBLO_FCM_CREDENTIALS_JSON",

    # SSO login (Sign in with Google) — stage 18. The expected audience of
    # the ID token the Android client posts to /auth/google: the *Web*
    # OAuth client ID (the Flutter serverClientId), NOT the Android client.
    # It's a public identifier (embedded in the app), not a secret, so its
    # real value lives in ssm_param_defaults below. Apple is omitted until
    # there's an Apple Developer account — config.py defaults it to unset,
    # so /auth/apple returns 503 until then.
    "SEMBLO_SSO_GOOGLE_CLIENT_ID",
  ]

  # Initial values for params where the generic "REPLACE_ME" stub would be
  # invalid (e.g. a bool) or where the value is public and can be committed.
  # Everything else starts as "REPLACE_ME".
  ssm_param_defaults = {
    SEMBLO_FCM_ENABLED          = "false"
    SEMBLO_SSO_GOOGLE_CLIENT_ID = "22611086967-o9tmb2p2rvoqfsiqcgcuqu8fu4tulkvs.apps.googleusercontent.com"
  }
}

resource "aws_ssm_parameter" "app" {
  for_each = toset(local.ssm_param_names)

  name  = "/semblo/${var.environment}/${each.key}"
  type  = "SecureString"
  value = lookup(local.ssm_param_defaults, each.key, "REPLACE_ME")

  lifecycle {
    ignore_changes = [value]
  }
}
