variable "aws_region" {
  description = "AWS region. Frankfurt by default — keeps the EC2 close to the user base."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Logical environment name; used in tags + resource names."
  type        = string
  default     = "prod"
}

variable "api_domain_name" {
  description = "Public hostname the API serves on."
  type        = string
  default     = "api.semblo.app"
}

variable "web_domain_name" {
  description = "Public hostname the marketing site serves on (apex)."
  type        = string
  default     = "semblo.app"
}

variable "hosted_zone_name" {
  description = "Route 53 hosted zone records go into. Must already exist."
  type        = string
  default     = "semblo.app"
}

variable "instance_type" {
  description = "EC2 instance type. ARM Graviton t4g.small is the cost sweet spot."
  type        = string
  default     = "t4g.small"
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB (gp3, encrypted)."
  type        = number
  default     = 30
}

variable "infra_repo" {
  description = "owner/repo of this infrastructure repo. Cloned onto the EC2 at boot for compose + Caddyfile."
  type        = string
}

variable "app_deploy_repos" {
  description = "List of owner/repo strings allowed to deploy apps via OIDC → SSM:SendCommand. The infra repo gets a separate, more privileged role."
  type        = list(string)
}

variable "github_branch" {
  description = "Branch on each repo authorized to deploy via OIDC."
  type        = string
  default     = "main"
}
