terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.95.1-rc1"
    }
  }
}

provider "proxmox" {
  endpoint  = var.endpoint
  api_token = "terraform@pve!provider=${var.api_token}"
  insecure  = true
  ssh {
    agent    = true
    username = "root"
  }
}