data "template_file" "server" {
  template = "${file("${path.module}/templates/provision.sh")}"

  vars {
    hostname                = "${var.hostname}"
    username                = "${var.username}"
    password                = "${var.password}"
    aws_access_key          = "${var.access_key}"
    aws_secret_key          = "${var.secret_key}"
    aws_region              = "${var.region}"
    envconsul_version       = "${var.envconsul_version}"
    consul_template_version = "${var.consul_template_version}"
    vault_url               = "${var.vault_url}"
  }
}

resource "aws_instance" "server" {
  ami           = "${data.aws_ami.ubuntu-1604.id}"
  instance_type = "r3.large"
  key_name      = "${aws_key_pair.demo.id}"

  subnet_id              = "${element(aws_subnet.demo.*.id, count.index)}"
  vpc_security_group_ids = ["${aws_security_group.demo.id}"]

  tags {
    "Name" = "vault.hashicorp.rocks"
  }

  user_data = "${data.template_file.server.rendered}"
}

output "ip" {
  value = "${aws_instance.server.public_ip}"
}

output "address" {
  value = "vault.hashicorp.rocks"
}
