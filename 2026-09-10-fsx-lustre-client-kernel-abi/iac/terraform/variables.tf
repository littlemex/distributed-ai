variable "region" {
  description = "AWS region that holds the subnet and the file system"
  type        = string
}

variable "subnet_id" {
  description = "Subnet in the same Availability Zone as the file system"
  type        = string
}

variable "file_system_security_group_ids" {
  description = "Security groups of the file system under test; the client joins them so the self-referencing Lustre rules apply"
  type        = list(string)
}

variable "ami_id" {
  description = "AMI to launch; when empty the SSM parameter below is resolved instead. Set this to verify an image that was baked with the client already installed"
  type        = string
  default     = ""
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter that resolves to the client AMI"
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "instance_type" {
  description = "Client instance type"
  type        = string
  default     = "m5.large"
}

variable "root_volume_gb" {
  description = "Root volume size in GiB"
  type        = number
  default     = 40
}

variable "name_prefix" {
  description = "Prefix for the names of the created resources"
  type        = string
  default     = "lustre-kernel-abi"
}

variable "tags" {
  description = "Tags applied to every created resource"
  type        = map(string)
  default     = {}
}
