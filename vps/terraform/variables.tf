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

