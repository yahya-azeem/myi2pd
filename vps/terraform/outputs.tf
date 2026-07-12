output "vps_ip" {
  value       = vultr_instance.myi2pd_vps.main_ip
  description = "Public IP address of the deployed VPS gateway"
}
