data "aws_route53_zone" "main" {
  name = var.hosted_zone_name
}

# api.semblo.app → EC2 EIP.
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.api_domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.api.public_ip]
}

# semblo.app (apex) → EC2 EIP. The same Caddy proxies / to the frontend container.
resource "aws_route53_record" "web" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.web_domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.api.public_ip]
}

# www.semblo.app → EC2 EIP. Caddy redirects www → apex in the site block.
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${var.web_domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.api.public_ip]
}
