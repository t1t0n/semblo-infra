output "instance_id" {
  description = "Set this as the GitHub repository variable `EC2_INSTANCE_ID` on semblo-backend, semblo-frontend, and semblo-infra so their CI can target it."
  value       = aws_instance.api.id
}

output "public_ip" {
  description = "Elastic IP attached to the EC2 instance."
  value       = aws_eip.api.public_ip
}

output "gh_app_role_arn" {
  description = "Set this as the GitHub repository secret `AWS_OIDC_ROLE_ARN` on semblo-backend AND semblo-frontend."
  value       = aws_iam_role.github_actions.arn
}

output "gh_infra_role_arn" {
  description = "Set this as the GitHub repository secret `AWS_OIDC_ROLE_ARN` on semblo-infra."
  value       = aws_iam_role.github_infra.arn
}

output "uploads_bucket" {
  description = "S3 bucket holding user-uploaded objects (avatars, trip covers, photos)."
  value       = aws_s3_bucket.uploads.bucket
}

output "backups_bucket" {
  description = "S3 bucket holding nightly pg_dump archives."
  value       = aws_s3_bucket.backups.bucket
}

output "api_url" {
  description = "Public URL for the API."
  value       = "https://${var.api_domain_name}"
}

output "web_url" {
  description = "Public URL for the marketing site."
  value       = "https://${var.web_domain_name}"
}
