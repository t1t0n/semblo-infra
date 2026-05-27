# ─────────────────────────────────────────────────────────────────────
# EC2 instance role: SSM Session Manager + read SSM parameters under
# /semblo/prod/* + R/W on the uploads bucket + write to backups bucket.
# ─────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "semblo-${var.environment}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Lets the box receive `aws ssm start-session` and run SSM:SendCommand.
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_inline" {
  statement {
    sid     = "ReadSemblowPrefixParams"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    # GetParametersByPath authorizes against the path itself (no trailing
    # slash), GetParameter/GetParameters against each child parameter.
    # Allow both forms.
    resources = [
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/semblo/${var.environment}",
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/semblo/${var.environment}/*",
    ]
  }

  statement {
    sid       = "DecryptSecureStrings"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    # Tighten to the SSM KMS alias if you ever provision a CMK.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }

  statement {
    sid     = "UploadsBucketRW"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.uploads.arn}/*",
    ]
  }

  statement {
    sid       = "UploadsBucketList"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.uploads.arn]
  }

  statement {
    sid       = "BackupsBucketWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_role_policy" "ec2_inline" {
  name   = "semblo-${var.environment}-ec2-inline"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_inline.json
}

resource "aws_iam_instance_profile" "ec2" {
  name = "semblo-${var.environment}-ec2"
  role = aws_iam_role.ec2.name
}

# ─────────────────────────────────────────────────────────────────────
# GitHub OIDC provider (one per AWS account).
# ─────────────────────────────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer verifies thumbprints when the provider URL has a well-known
  # certificate authority (which GitHub does). The value is required but
  # otherwise inert; AWS-published value below is the conventional stub.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ─────────────────────────────────────────────────────────────────────
# App-deploy role — used by semblo-backend + semblo-frontend.
# Permissions: SSM SendCommand on the one EC2 box.
# Trust:       any repo in var.app_deploy_repos, on var.github_branch.
# ─────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "gh_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        for r in var.app_deploy_repos :
        "repo:${r}:ref:refs/heads/${var.github_branch}"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "semblo-${var.environment}-gh-actions"
  assume_role_policy = data.aws_iam_policy_document.gh_actions_assume.json
}

data "aws_iam_policy_document" "gh_actions_inline" {
  statement {
    sid     = "SendCommandToTheInstance"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.api.id}",
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    sid       = "ReadCommandResults"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gh_actions_inline" {
  name   = "semblo-${var.environment}-gh-actions-inline"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.gh_actions_inline.json
}

# ─────────────────────────────────────────────────────────────────────
# Infra-deploy role — used by THIS repo (semblo-infra).
# Trust:       only var.infra_repo, on var.github_branch.
# Permissions: full administrator — TF manages IAM, EC2, Route53, S3, SSM,
#              and needs to grant itself new permissions as the stack grows.
#              Tighten to a curated policy if/when you want least-privilege.
# ─────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "gh_infra_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.infra_repo}:ref:refs/heads/${var.github_branch}"]
    }
  }
}

resource "aws_iam_role" "github_infra" {
  name               = "semblo-${var.environment}-gh-infra"
  assume_role_policy = data.aws_iam_policy_document.gh_infra_assume.json
}

resource "aws_iam_role_policy_attachment" "gh_infra_admin" {
  role       = aws_iam_role.github_infra.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
