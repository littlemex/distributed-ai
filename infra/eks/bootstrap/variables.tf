variable "region" {
  description = "AWS region where the state bucket and lock table are created."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must look like a standard AWS region name."
  }
}

variable "aws_profile" {
  description = "Optional named AWS profile for the aws provider."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.aws_profile == null ? true : trimspace(var.aws_profile) != ""
    error_message = "aws_profile must be null or a non-empty profile name."
  }
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket that stores versioned Terraform state objects."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be 3-63 characters of lowercase letters, numbers, periods, or hyphens, and must start and end with a letter or number."
  }

  validation {
    condition     = !can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$", var.state_bucket_name))
    error_message = "state_bucket_name must not be formatted like an IPv4 address."
  }

  validation {
    condition     = !strcontains(var.state_bucket_name, "..")
    error_message = "state_bucket_name must not contain consecutive periods."
  }
}

variable "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,255}$", var.lock_table_name))
    error_message = "lock_table_name must be 3-255 characters of letters, numbers, underscores, periods, or hyphens."
  }
}

variable "state_key" {
  description = "Object key inside the state bucket that the parent infra/eks module will use."
  type        = string

  validation {
    condition     = trimspace(var.state_key) != "" && !startswith(var.state_key, "/") && !endswith(var.state_key, "/")
    error_message = "state_key must be a non-empty object key and must not start or end with '/'."
  }
}

variable "kms_key_id" {
  description = "Optional KMS key id, ARN, or alias for bucket encryption and the generated backend.hcl. Null uses the AWS-managed aws/s3 key."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.kms_key_id == null ? true : can(regex(
      "^(arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:(key|alias)/.+|alias/[A-Za-z0-9/_-]+|mrk-[0-9A-Fa-f]{32}|[0-9A-Fa-f-]{36})$",
      var.kms_key_id
    ))
    error_message = "kms_key_id must be null or a KMS key ARN, alias, multi-Region key id, or UUID-style key id."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent S3 object versions before S3 expires them."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1 && var.noncurrent_version_expiration_days <= 3650
    error_message = "noncurrent_version_expiration_days must be between 1 and 3650."
  }
}

variable "tags" {
  description = "Additional tags applied to the state bucket and lock table."
  type        = map(string)
  default     = {}
}
