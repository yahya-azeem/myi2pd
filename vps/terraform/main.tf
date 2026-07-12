terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.15.0"
    }
  }
}

provider "vultr" {
  api_key = var.vultr_api_key
}

resource "vultr_ssh_key" "myi2pd_key" {
  name    = "myi2pd-ssh-key"
  ssh_key = var.ssh_public_key
}

resource "vultr_instance" "myi2pd_vps" {
  plan        = "vc2-1c-0.5gb" # Vultr Cloud Compute Free Tier / lowest tier (1 vCPU, 512MB RAM)
  region      = var.vultr_region
  os_id       = 382 # OS ID for Alpine Linux
  label       = "myi2pd-gateway"
  tag         = "myi2pd"
  hostname    = "myi2pd-gateway"
  enable_ipv6 = false
  backups     = "disabled"
  ddos        = false

  ssh_key_ids = [vultr_ssh_key.myi2pd_key.id]

  provisioner "file" {
    source      = "../configs"
    destination = "/etc/myi2pd-configs"

    connection {
      type        = "ssh"
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.main_ip
    }
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /etc/myi2pd-configs/setup_vps.sh",
      "/etc/myi2pd-configs/setup_vps.sh"
    ]

    connection {
      type        = "ssh"
      user        = "root"
      private_key = file(var.ssh_private_key_path)
      host        = self.main_ip
    }
  }
}
