variable "endpoint" {
  description = "Endpoint for proxmox server"
  type        = string
  default     = "http://192.168.68.100:8006"
}

variable "api_token" {
  description = "api token for authentication with the server"
  type        = string
  default     = ""
  sensitive   = true
}

variable "agent_username" {
  description = "ssh agent username"
  type        = string
  default     = "root"
}

variable "agent_password" {
  description = "ssh agent password"
  type        = string
  default     = ""
  sensitive   = true
}

variable "vm_nodes" {
  type = map(object({
    id  = number
    cpu = number
    ram = number
    ip  = string
    disks = list(object({
      size         = number
      datastore_id = string
      file_id      = optional(string) # Only needed for the OS disk
    }))
  }))
}