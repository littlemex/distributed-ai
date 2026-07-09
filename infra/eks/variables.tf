variable "region" {
  description = "AWS region where the cluster is deployed."
  type        = string
  default     = "us-east-2"
}

variable "azs" {
  description = "List of availability zones. Capacity Blocks are single-AZ; set exactly one AZ that matches the CB offering."
  type        = list(string)
  default     = ["us-east-2a"]
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "distai-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Verified available: 1.35. (terraform-aws-eks v21.24.0 uses 'kubernetes_version', not 'cluster_version'.)"
  type        = string
  default     = "1.35"
}

variable "instance_type" {
  description = "EC2 instance type for GPU worker nodes. p5en.48xlarge = H200 x8, EFA x16."
  type        = string
  default     = "p5en.48xlarge"
}

variable "cb_reservation_id" {
  description = "Capacity Block reservation ID (cr-xxx) obtained from purchase-capacity-block. Empty string disables CB NodePool."
  type        = string
  default     = ""
}

variable "cb_end_date" {
  description = "Expiry datetime of the Capacity Block in RFC3339 format (e.g. 2024-12-31T23:59:59Z). Used to set Karpenter NodePool expireAfter."
  type        = string
  default     = ""
}

variable "aws_account_id" {
  description = "AWS account ID where the cluster resources are created."
  type        = string
  default     = "" # required: set to your AWS account ID
}

variable "aws_profile" {
  description = "AWS CLI/Terraform provider profile name."
  type        = string
  default     = "default" # AWS named profile for authentication
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /21 gives 2048 addresses, sufficient for a single-AZ GPU cluster."
  type        = string
  default     = "10.0.0.0/21"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ). Node workloads run here."
  type        = list(string)
  default     = ["10.0.0.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ). NAT gateway and load balancers."
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "environment" {
  description = "Deployment environment label (e.g. dev, staging, prod). Used in resource tags."
  type        = string
  default     = "dev"
}

variable "gpu_operator_install_driver" {
  description = "Whether the NVIDIA GPU Operator should install the GPU driver. Set false when the EKS AMI already ships with the driver (typical for Capacity Block GPU AMIs)."
  type        = bool
  default     = false
}

variable "fsx_per_unit_storage_throughput" {
  description = "FSx for Lustre per-unit storage throughput in MB/s/TiB. Valid values for PERSISTENT_2 SSD: 125, 250, 500, 1000."
  type        = number
  default     = 250
}

variable "fsx_storage_capacity_gib" {
  description = "FSx for Lustre storage capacity in GiB. Must be a multiple of 2400 for PERSISTENT_2 SSD."
  type        = number
  default     = 4800
}

variable "fsx_csi_driver_role_arn" {
  description = "ARN of the IRSA / Pod Identity role for the aws-fsx-csi-driver addon. Leave empty to omit the IRSA binding (suitable when using EKS Pod Identity)."
  type        = string
  default     = ""
}

variable "cb_alert_email_addresses" {
  description = "List of email addresses to notify 1 hour before the Capacity Block expires. Leave empty to skip SNS subscriptions."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "distributed-ai"
    ManagedBy = "terraform"
  }
}
