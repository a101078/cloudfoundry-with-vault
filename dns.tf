provider "cloudflare" {
  email = "${var.cloudflare_email}"
  token = "${var.cloudflare_token}"
}

resource "cloudflare_record" "vault" {
  domain  = "hashicorp.rocks"
  type    = "A"
  name    = "vault"
  value   = "${aws_instance.server.public_ip}"
  ttl     = "1"
  proxied = "1"
}
