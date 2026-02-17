resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_image" {
  content_type = "import"
  datastore_id = "local" 
  node_name    = "pve"
  url          = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  file_name    = "ubuntu-jammy.qcow2"
}

resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  for_each     = var.vm_nodes
  content_type = "snippets"
  datastore_id = "local" 
  node_name    = "pve"

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: ${each.key}
    users:
      - name: rashed
        groups: [sudo]
        shell: /bin/bash
        ssh_authorized_keys:
          - ${file("./id_ed25519.pub")}
        sudo: ALL=(ALL) NOPASSWD:ALL
    package_update: true
    packages:
      - qemu-guest-agent
      - curl
      - net-tools
    runcmd:
      - systemctl enable qemu-guest-agent
      - systemctl start qemu-guest-agent
    EOF

    file_name = "user-data-${each.key}.yaml"
  }
}


resource "proxmox_virtual_environment_vm" "k3s_node" {
  for_each = var.vm_nodes

  name      = each.key
  node_name = "pve"
  vm_id     = each.value.id

  
  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cpu
    type  = "host" 
  }

  memory {
    dedicated = each.value.ram
  }

  
  dynamic "disk" {
    for_each = each.value.disks
    content {
      datastore_id = disk.value.datastore_id
      size         = disk.value.size
      interface    = "virtio${disk.key}"
      iothread     = true
      discard      = "on" 
      
      
      file_id = disk.key == 0 ? proxmox_virtual_environment_download_file.ubuntu_cloud_image.id : null
    }
  }

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = "192.168.68.1"
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.user_data_cloud_config[each.key].id
  }

  network_device {
    bridge = "vmbr0"
  }
}