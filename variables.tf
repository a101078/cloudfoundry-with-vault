variable "access_key" {}

variable "secret_key" {}

variable "region" {
  default = "us-east-1"
}

variable "consul_template_version" {
  default = "0.18.3"
}

variable "envconsul_version" {
  default = "0.6.2"
}

variable "vault_url" {
  default = "https://releases.hashicorp.com/vault/0.7.3/vault_0.7.3_linux_amd64.zip"
}

variable "namespace" {}

variable "vpc_cidr_block" {
  default = "10.1.0.0/16"
}

variable "cidr_blocks" {
  default = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "hostname" {
  default = "vault.hashicorp.rocks"
}

variable "username" {
  default = "demo"
}

variable "password" {
  default = "pray-to-the-demo-gods"
}

variable "public_key_path" {
  default = "~/.ssh/id_rsa.pub"
}

variable "cloudflare_email" {}

variable "cloudflare_token" {}
