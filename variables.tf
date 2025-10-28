variable "aws_region" {
  type        = string
  description = "AWS Region name"
}

variable "domain_name" {
  type        = string
  description = "Domain name"
}

variable "s3_bucket_name" {
  type        = string
  description = "S3 bucket name"
}

variable "namespace_id" {
  type        = string
  description = "Mendix Private Cloud Namespace ID"
  default     = ""
}

variable "namespace_secret" {
  type        = string
  description = "Mendix Private Cloud Namespace Secret"
  default     = ""
}

variable "eks_node_instance_type" {
  type        = string
  description = "EKS instance type"
  default     = "t3.medium"
}

variable "eks_cluster_name_prefix" {
  type        = string
  description = "EKS name prefix for the new cluster"
  default     = "mendix-eks"

  validation {
    condition     = length(var.eks_cluster_name_prefix) < 65 && can(regex("^[0-9A-Za-z][A-Za-z0-9\\-_]*", var.eks_cluster_name_prefix))
    error_message = "EKS name prefix max length is 65 and it should have the next patter: ^[0-9A-Za-z][A-Za-z0-9\\-_]*"
  }
}

variable "mendix_operator_version" {
  type        = string
  description = "Mendix Private Cloud Operator version"
  default     = "2.20.1"
}

variable "certificate_expiration_email" {
  type        = string
  description = "Let's Encrypt certificate expiration email"
}

variable "allowed_ips" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "List of IP adresses allowed to access EKS cluster endpoint"
}

variable "environments_internal_names" {
  type        = list(string)
  default     = ["app1"]
  description = "List of internal environments names"

  validation {
    condition     = alltrue([for app in var.environments_internal_names : can(regex("^[a-z0-9]{1,8}$", app))])
    error_message = "Use only lowercase letters and numbers, with a maximum of 8 characters and a minimum of 1 character."
  }
}

variable "postgres_version" {
  type        = string
  description = "The version of Postgres to deploy"
  default     = "14.15"
}

variable "kubernetes_version" {
  type        = string
  description = "The version of Kubernetes to deploy"
  default     = "1.33"
}

variable "vpc_id" {
  type        = string
  description = "The VPC ID where the EKS cluster will be deployed."
}

variable "vpc_private_subnets" {
  type        = list(string)
  description = "A list of private subnet IDs within the specified VPC for the EKS cluster."
}

# TODO: use `access_entries` instead of auth_configmap with v20+ of the terraform-aws-eks module
variable "eks_cluster_admin_role_arns" {
  description = "List of IAM role ARNs that should have system:masters access to the EKS cluster"
  type        = list(string)
  default     = []
}


variable "kms_key_admin_arns_list" {
  type        = list(string)
  description = "List of ARNs for KMS key administrators."
  default     = []
}

variable "kms_key_user_arns_list" {
  type        = list(string)
  description = "List of ARNs for KMS key users."
  default     = []
}