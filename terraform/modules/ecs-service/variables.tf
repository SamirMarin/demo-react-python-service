variable "name" {
  description = "Name prefix used for the cluster, service, and related resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the service's tasks run in."
  type        = list(string)
}

variable "container_image" {
  description = "Container image to run."
  type        = string
  default     = "nginx:latest"
}

variable "container_port" {
  description = "Port the container listens on."
  type        = number
  default     = 80
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Fargate task memory (MB)."
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Baseline number of tasks."
  type        = number
  default     = 1
}

variable "min_capacity" {
  description = "Minimum tasks the autoscaler can scale down to."
  type        = number
  default     = 1
}

variable "max_capacity" {
  description = "Maximum tasks the autoscaler can scale up to."
  type        = number
  default     = 4
}

variable "cpu_target_value" {
  description = "Target average CPU utilization (%) the autoscaler tries to maintain."
  type        = number
  default     = 60
}
