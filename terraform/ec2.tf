data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_eip" "api" {
  domain = "vpc"

  tags = {
    Name = "semblo-${var.environment}-api"
  }

  lifecycle {
    # Losing the EIP means DNS needs updating + ACME certs need re-issuing.
    # Hard-block destroy; remove this block (carefully) only when migrating.
    prevent_destroy = true
  }
}

resource "aws_instance" "api" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.api.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # Force IMDSv2 — token-required metadata access. Best-practice default
  # since 2020; blocks the SSRF → creds path entirely.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/../deploy/user_data.sh", {
    aws_region     = var.aws_region
    infra_repo     = var.infra_repo
    backups_bucket = aws_s3_bucket.backups.bucket
  })

  # Changing user_data triggers a full instance replacement (which loses
  # the Postgres volume!). For ongoing changes, edit files in deploy/ and
  # run `aws ssm send-command` to apply them — see CUTOVER.md.
  user_data_replace_on_change = false

  tags = {
    Name = "semblo-${var.environment}-api"
  }

  # Ensure SSM params exist before the instance boots (user_data reads them).
  depends_on = [aws_ssm_parameter.app]

  lifecycle {
    # The aws_ami data source picks `most_recent`, so AL2023 AMI rotation
    # would otherwise force-replace the instance (destroying the Postgres
    # volume on root EBS). Ignore drift here — upgrade the box explicitly
    # via `terraform taint aws_instance.api` when you actually want to.
    #
    # user_data is also ignored: cloud-init only runs at first boot, so
    # editing deploy/user_data.sh has zero effect on a running instance.
    # We change live config via SSM SendCommand from .github/workflows/.
    ignore_changes = [ami, user_data]

    # Belt-and-suspenders: even if someone edits a ForceNew field
    # (subnet_id, key_name, root_block_device.volume_type/encrypted), TF
    # refuses to plan a destroy here. Removing this block is a deliberate
    # act that has to land in its own commit — there is no accidental path
    # to wiping the Postgres volume.
    prevent_destroy = true
  }
}

resource "aws_eip_association" "api" {
  instance_id   = aws_instance.api.id
  allocation_id = aws_eip.api.id
}
