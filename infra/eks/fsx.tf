# fsx.tf
# FSx for Lustre file system for shared training data / checkpoints.
# prevent_destroy = true to guard against accidental deletion of training data.
#
# Verified facts (VERIFIED_FACTS.md):
#   - aws-fsx-csi-driver EKS addon: v1.9.0-eksbuild.1
#   - region and account are taken from the configured AWS provider

# ---------------------------------------------------------------------------
# FSx for Lustre file system
# ---------------------------------------------------------------------------
resource "aws_fsx_lustre_file_system" "training" {
  # Single-AZ placement aligned with the Capacity Block AZ (first private subnet).
  subnet_ids = [module.vpc.private_subnets[0]]

  security_group_ids = [aws_security_group.fsx.id]

  # PERSISTENT_2 supports SSD storage and is required for data repository associations.
  deployment_type = "PERSISTENT_2"

  # 1.2 GiB/s/TiB is the minimum for PERSISTENT_2 with SSD.
  per_unit_storage_throughput = var.fsx_per_unit_storage_throughput

  # Storage capacity must be a multiple of 2400 GiB for PERSISTENT_2 SSD.
  storage_capacity = var.fsx_storage_capacity_gib

  storage_type = "SSD"

  # Lustre-specific configuration.
  data_compression_type = "LZ4"

  tags = {
    Name        = "${var.cluster_name}-fsx-lustre"
    Environment = var.environment
    Project     = "distributed-ai"
  }

  lifecycle {
    # Protect training data and checkpoints from accidental destroy.
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Security group for FSx — allow Lustre (988) from the EKS node CIDR
# ---------------------------------------------------------------------------
resource "aws_security_group" "fsx" {
  name        = "${var.cluster_name}-fsx-sg"
  description = "Allow Lustre traffic from EKS nodes to FSx for Lustre"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Lustre port 988 from EKS nodes"
    from_port   = 988
    to_port     = 988
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  ingress {
    description = "Lustre high ports 1018-1023 from EKS nodes"
    from_port   = 1018
    to_port     = 1023
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-fsx-sg"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------------
# aws-fsx-csi-driver EKS addon
# Version v1.9.0-eksbuild.1 confirmed (VERIFIED_FACTS.md).
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "fsx_csi_driver" {
  cluster_name  = var.cluster_name
  addon_name    = "aws-fsx-csi-driver"
  addon_version = "v1.9.0-eksbuild.1"
  # Omit IRSA binding when empty (use EKS Pod Identity or instance profile instead).
  service_account_role_arn = var.fsx_csi_driver_role_arn != "" ? var.fsx_csi_driver_role_arn : null

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }
}

# ---------------------------------------------------------------------------
# StorageClass for dynamic FSx PVC provisioning via CSI driver
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "fsx_storage_class" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "fsx-lustre"
    }
    provisioner   = "fsx.csi.aws.com"
    reclaimPolicy = "Retain"
    parameters = {
      subnetId         = module.vpc.private_subnets[0]
      securityGroupIds = aws_security_group.fsx.id
      deploymentType   = "PERSISTENT_2"
      # Reference the static file system created above for static provisioning,
      # or remove fileSystemId to allow dynamic provisioning.
      fileSystemId = aws_fsx_lustre_file_system.training.id
    }
  })

  depends_on = [aws_eks_addon.fsx_csi_driver]
}
