output "vm_ips" {
  value = { for k, v in proxmox_virtual_environment_vm.k3s_node : k => v.initialization[0].ip_config[0].ipv4[0].address }
}