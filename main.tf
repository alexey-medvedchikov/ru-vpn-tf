terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }

    tls = {
      source = "hashicorp/tls"
    }

    random = {
      source = "hashicorp/random"
    }

    local = {
      source = "hashicorp/local"
    }

    null = {
      source = "hashicorp/null"
    }
  }
}

provider "yandex" {
  service_account_key_file = "service-account.json"
}


locals {
  name_prefix = "vpn"
  zone        = "ru-central1-a"
  user        = "admin"
  vpn_user    = "vpnuser"
  cidr_block  = "10.10.0.0/24"
}

data "yandex_compute_image" "this" {
  family = "openvpn"
}

resource "yandex_vpc_network" "this" {
  name = local.name_prefix
}

resource "yandex_vpc_subnet" "this" {
  name           = local.name_prefix
  zone           = local.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [local.cidr_block]
}

resource "yandex_vpc_security_group" "this" {
  name       = local.name_prefix
  network_id = yandex_vpc_network.this.id

  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "OpenVPN UDP"
    protocol       = "UDP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 1194
    to_port        = 1194
  }

  ingress {
    description    = "SSH"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = "22"
    to_port        = "22"
  }

  ingress {
    description    = "HTTPS"
    protocol       = "TCP"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = "443"
    to_port        = "443"
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "random_password" "vpn" {
  length  = 30
  special = false
}

resource "yandex_compute_instance" "this" {
  name = local.name_prefix
  zone = local.zone

  resources {
    cores         = 2
    core_fraction = 20
    memory        = 1
  }

  scheduling_policy {
    preemptible = true
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.this.id
    security_group_ids = [yandex_vpc_security_group.this.id]
    nat                = true
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.this.image_id
      size     = 3
    }
  }

  metadata = {
    install-unified-agent = "0"
    ssh-keys              = "${local.user}:${tls_private_key.ssh.public_key_openssh}"
    user-data             = <<EOF
#cloud-config
datasource:
  Ec2:
    strict_id: false
ssh_pwauth: no
users:
- name: ${local.user}
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: /bin/bash
  ssh_authorized_keys:
  - ${tls_private_key.ssh.public_key_openssh}
EOF
  }

  connection {
    type        = "ssh"
    user        = local.user
    private_key = tls_private_key.ssh.private_key_openssh
    host        = self.network_interface.0.nat_ip_address
  }

  provisioner "remote-exec" {
    inline = [
      "while ! sudo /usr/local/openvpn_as/scripts/sacli Status >/dev/null 2>&1; do sleep 1; done",
      "sudo /usr/local/openvpn_as/scripts/sacli --user '${local.vpn_user}' --new_pass '${random_password.vpn.result}' SetLocalPassword",
      "sudo /usr/local/openvpn_as/scripts/sacli --prefer-tls-crypt-v2 --user '${local.vpn_user}' GetUserlogin >/tmp/profile.ovpn",
    ]
  }
}

resource "local_file" "ssh_key" {
  filename        = "${path.cwd}/ssh_key"
  file_permission = "0600"
  content         = tls_private_key.ssh.private_key_openssh
}

resource "local_file" "credentials" {
  filename        = "${path.cwd}/profile-auth.txt"
  file_permission = "0600"
  content         = <<EOF
${local.vpn_user}
${random_password.vpn.result}
EOF
}

resource "null_resource" "openvpn_profile" {
  provisioner "local-exec" {
    command = "scp -i '${local_file.ssh_key.filename}' '${local.user}@${yandex_compute_instance.this.network_interface.0.nat_ip_address}':/tmp/profile.ovpn '${path.cwd}/profile.ovpn'"
  }
}
