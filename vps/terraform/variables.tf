variable "vultr_api_key" {
  type        = string
  description = "Vultr API Key"
  sensitive   = true
}

variable "vultr_region" {
  type        = string
  description = "Vultr Region (e.g. ewr for New Jersey)"
  default     = "ewr"
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key to install on the instance"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Local path to the private SSH key corresponding to ssh_public_key"
  default     = "~/.ssh/id_rsa"
}
