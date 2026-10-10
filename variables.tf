variable "cloudflare_api_token" {
  type        = string
  description = "Cloudflare API Token with DNS Edit permissions"
  sensitive   = true
  default     = null
}

variable "karpenter_capacity_enabled" {
  type        = bool
  default     = false
  description = "Enable the dynamic NodePool only after controller/bootstrap readiness checks."
}
variable "karpenter_cpu_limit" {
  type        = number
  default     = 16
  description = "Aggregate dynamic vCPU guardrail, not a spending cap."
  validation {
    condition     = var.karpenter_cpu_limit > 0 && var.karpenter_cpu_limit <= 64
    error_message = "CPU limit must be positive and at most 64 vCPU for this lab."
  }
}
variable "karpenter_memory_limit" {
  type        = string
  default     = "64Gi"
  description = "Aggregate dynamic memory guardrail."
  validation {
    condition     = can(regex("^[1-9][0-9]*Gi$", var.karpenter_memory_limit))
    error_message = "Use a positive integer Gi quantity."
  }
}
variable "karpenter_capacity_type" {
  type        = string
  default     = "spot"
  description = "Workload purchase option; on-demand requires explicit owner approval/configuration."
  validation {
    condition     = contains(["spot", "on-demand"], var.karpenter_capacity_type)
    error_message = "Capacity type must be spot or on-demand."
  }
}
variable "karpenter_instance_families" {
  type        = list(string)
  default     = ["m5", "m5a", "m6i", "m6a", "c5", "c5a", "c6i", "c6a", "r5", "r5a", "r6i", "r6a"]
  description = "Multiple standard amd64 families; accelerator families are forbidden."
  validation {
    condition     = length(var.karpenter_instance_families) >= 2 && alltrue([for f in var.karpenter_instance_families : contains(["m5", "m5a", "m6i", "m6a", "c5", "c5a", "c6i", "c6a", "r5", "r5a", "r6i", "r6a"], f)])
    error_message = "Choose at least two of the supported standard instance families."
  }
}
variable "karpenter_instance_sizes" {
  type        = list(string)
  default     = ["large", "xlarge"]
  description = "Bounded standard workload sizes."
  validation {
    condition     = length(var.karpenter_instance_sizes) > 0 && alltrue([for s in var.karpenter_instance_sizes : contains(["large", "xlarge"], s)])
    error_message = "Choose large and/or xlarge."
  }
}
variable "karpenter_consolidate_after" {
  type        = string
  default     = "5m"
  description = "Quiet period before empty/underutilized consolidation."
  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h)$", var.karpenter_consolidate_after))
    error_message = "Use a positive duration such as 5m."
  }
}
