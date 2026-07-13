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
  filter {
    name   = "description"
    values = ["myi2pd-hardened-alpine-vps"]
  }
}

resource "vultr_instance" "myi2pd_vps" {
  plan        = "vps-free-1c-0.5gb-10gb" # Vultr Cloud Compute Free Tier (1 vCPU, 512MB RAM, 10GB Disk)
  region      = var.vultr_region
  snapshot_id = data.vultr_snapshot.myi2pd_snap.id
  label       = "myi2pd-gateway"
  tag         = "myi2pd"
  hostname    = "myi2pd-gateway"
  enable_ipv6 = false
  backups     = "disabled"
  ddos        = false

  ssh_key_ids = [vultr_ssh_key.myi2pd_key.id]
}
