# vps_image.pkr.hcl - Packer configuration to build a hardened Alpine Linux snapshot on Vultr

packer {
  required_plugins {
    vultr = {
      version = ">= 1.1.1"
      source  = "github.com/vultr/vultr"
    }
  }
}

variable "vultr_api_key" {
  type      = string
  default   = env("VULTR_API_KEY")
  sensitive = true
}

source "vultr" "myi2pd_alpine" {
  api_key              = var.vultr_api_key
  os_id                = 382 # Alpine Linux
  plan_id              = "vc2-1c-0.5gb" # Free Tier / low tier specs (1 vCPU, 512MB RAM)
  region_id            = "ewr" # Default region (New Jersey)
  snapshot_description = "myi2pd-hardened-alpine-vps"
  ssh_username         = "root"
  state_timeout        = "10m"
}

build {
  sources = ["source.vultr.myi2pd_alpine"]

  # Provision files
  provisioner "file" {
    source      = "../configs"
    destination = "/etc/myi2pd-configs"
  }

  # Execute hardening script
  provisioner "shell" {
    inline = [
      "chmod +x /etc/myi2pd-configs/setup_vps.sh",
      "/etc/myi2pd-configs/setup_vps.sh"
    ]
  }
}
