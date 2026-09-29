variable "subscription_id" {
  description = "The subscription selected with az account set."
  type        = string
}

variable "prefix" {
  description = "Your short project/student prefix; a random suffix makes globally unique names."
  type        = string
  default     = "lsdemo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.prefix))
    error_message = "Use 3-12 lowercase letters/numbers, starting with a letter."
  }
}

variable "location" {
  description = "An Azure region where your subscription has AKS and PostgreSQL quota."
  type        = string
  default     = "westeurope"
}

variable "operator_ipv4_cidr" {
  description = "Your current public IPv4 followed by /32; permits local Key Vault access and access to the AKS Kubernetes API."
  type        = string

  validation {
    condition = (
      can(cidrhost(var.operator_ipv4_cidr, 0)) &&
      can(regex("^[0-9.]+/32$", var.operator_ipv4_cidr))
    )
    error_message = "Supply your public IPv4 in /32 form, for example 203.0.113.10/32 (replace this documentation address)."
  }
}

variable "aks_api_additional_cidrs" {
  description = "Optional fixed public IPv4 /32 addresses for other authorized operators or deployment runners."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.aks_api_additional_cidrs :
      can(cidrhost(cidr, 0)) && can(regex("^[0-9.]+/32$", cidr))
    ])
    error_message = "Every additional address must be a specific public IPv4 /32."
  }
}

variable "aks_vm_size" {
  description = "System-pool VM size: current AKS guidance requires at least 4 vCPUs; check regional SKU availability."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "aks_node_count" {
  description = "Current AKS system-pool minimum is two nodes. This setting is separate from Pod HPA."
  type        = number
  default     = 2

  validation {
    condition     = var.aks_node_count >= 2 && floor(var.aks_node_count) == var.aks_node_count
    error_message = "Use an integer of at least 2 for the system node pool."
  }
}

variable "postgres_sku" {
  description = "Small burstable PostgreSQL size for the teaching lab; verify subscription/region availability."
  type        = string
  default     = "B_Standard_B1ms"
}

variable "tags" {
  description = "Tags for the project resources."
  type        = map(string)
  default = {
    project     = "learningsteps"
    environment = "training"
  }
}
