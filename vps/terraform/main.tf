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

data "vultr_snapshot" "myi2pd_snap" {
  count = var.use_packer_snapshot ? 1 : 0
  filter {
    name   = "description"
    values = ["myi2pd-hardened-alpine-vps"]
  }
}

resource "vultr_instance" "myi2pd_vps" {
  plan        = "vc2-1c-0.5gb" # Vultr Cloud Compute Free Tier / lowest tier (1 vCPU, 512MB RAM)
  region      = var.vultr_region
  os_id       = var.use_packer_snapshot ? null : 382 # OS ID for Alpine Linux (only if not using snapshot)
  snapshot_id = var.use_packer_snapshot ? data.vultr_snapshot.myi2pd_snap[0].id : null
  label       = "myi2pd-gateway"
  tag         = "myi2pd"
  hostname    = "myi2pd-gateway"
  enable_ipv6 = false
  backups     = "disabled"
  ddos        = false

  ssh_key_ids = [vultr_ssh_key.myi2pd_key.id]
}

# Conditional provisioning: Only executes if NOT deploying from pre-built Packer snapshot
resource "null_resource" "provision_vps" {
  count = var.use_packer_snapshot ? 0 : 1

  triggers = {
    instance_id = vultr_instance.myi2pd_vps.id
  }

  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    host        = vultr_instance.myi2pd_vps.main_ip
  }

  provisioner "file" {
    source      = "../configs"
    destination = "/etc/myi2pd-configs"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /etc/myi2pd-configs/setup_vps.sh",
      "/etc/myi2pd-configs/setup_vps.sh"
    ]
  }
}
