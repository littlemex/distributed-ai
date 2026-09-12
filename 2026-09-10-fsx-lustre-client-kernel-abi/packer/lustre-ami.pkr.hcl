// Bake the FSx for Lustre client into an AMI.
//
// The build has two stages with a reboot between them, and the reboot is only needed when a kernel
// line is pinned. A module can be built for a kernel that is not running, given its headers; the
// reboot is here because the installer targets the running kernel by default, and because it lets
// the image prove the module loads on the kernel the image actually boots. Leave lustre_kernel_meta
// empty and the first stage and the reboot do nothing.
//
//   packer init lustre-ami.pkr.hcl
//   packer build -var parent_ami_ssm=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id lustre-ami.pkr.hcl
//
// The same template bakes an EKS node image by pointing parent_ami_ssm at that image's parameter.

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "parent_ami_ssm" {
  type        = string
  description = "Public SSM parameter that resolves to the parent Ubuntu AMI"
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "instance_type" {
  type        = string
  description = "The build compiles a kernel module, so it wants cores rather than accelerators"
  default     = "m5.2xlarge"
}

variable "ami_name_prefix" {
  type    = string
  default = "lustre-client"
}

variable "lustre_mode" {
  type        = string
  description = "build bakes the module into the image; dkms registers the source so the module follows kernel installs on the running host"
  default     = "build"
}

variable "lustre_kernel_meta" {
  type        = string
  description = "Kernel line to pin before the client is installed, for example linux-aws-lts-24.04. Empty keeps the kernel the parent image booted and skips the reboot"
  default     = ""
}

data "amazon-parameterstore" "parent" {
  name   = var.parent_ami_ssm
  region = var.aws_region
}

locals {
  timestamp = regex_replace(timestamp(), "[- TZ:]", "")
}

source "amazon-ebs" "lustre" {
  ami_name      = "${var.ami_name_prefix}-${local.timestamp}"
  instance_type = var.instance_type
  region        = var.aws_region
  source_ami    = data.amazon-parameterstore.parent.value
  ssh_username  = "ubuntu"

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  // The source tree, the build and the kernel headers together need more than the parent image's
  // root volume carries.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    ParentAMI    = data.amazon-parameterstore.parent.value
    ParentLookup = var.parent_ami_ssm
    LustreClient = "source-build"
    LustreMode   = var.lustre_mode
  }
}

build {
  name    = "lustre"
  sources = ["source.amazon-ebs.lustre"]

  provisioner "ansible" {
    user          = "ubuntu"
    playbook_file = "../ansible/playbook-lustre-kernel.yml"
    extra_arguments = [
      "--extra-vars", "aws_lustre_kernel_meta=${var.lustre_kernel_meta}"
    ]
  }

  // expect_disconnect is what lets the build survive the reboot it just asked for.
  provisioner "shell" {
    expect_disconnect = true
    inline            = ["sudo systemctl reboot"]
  }

  provisioner "ansible" {
    user          = "ubuntu"
    playbook_file = "../ansible/playbook-lustre.yml"
    pause_before  = "30s"
    extra_arguments = [
      "--extra-vars", "aws_lustre_mode=${var.lustre_mode}",
      "--extra-vars", "aws_lustre_kernel_meta=${var.lustre_kernel_meta}"
    ]
  }
}
