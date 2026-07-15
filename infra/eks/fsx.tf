# fsx.tf
# FSx for Lustre — optional single-AZ, high-throughput scratch/checkpoint filesystem.
# Gated by var.fsx_enabled (off by default: PERSISTENT_2 provisions TBs of SSD that bill
# continuously). prevent_destroy is intentionally NOT set so the environment stays
# destroyable; teardown deletes the filesystem and its data (regenerable caches). Set
# prevent_destroy = true for a long-lived cluster holding irreplaceable data.
#
# Notes:
#   - aws-fsx-csi-driver EKS addon: v1.9.0-eksbuild.1
#   - region and account are taken from the configured AWS provider

# ---------------------------------------------------------------------------
# FSx for Lustre file system
# ---------------------------------------------------------------------------
resource "aws_fsx_lustre_file_system" "training" {
  count = var.fsx_enabled ? 1 : 0
  # Single-AZ placement aligned with the Capacity Block AZ (first private subnet).
  subnet_ids = [module.vpc.private_subnets[0]]

  security_group_ids = [aws_security_group.fsx[0].id]

  # PERSISTENT_2 supports SSD storage and is required for data repository associations.
  deployment_type = "PERSISTENT_2"

  # PERSISTENT_2 SSD supports 125/250/500/1000 MB/s/TiB (125 is the minimum).
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

  # NOTE: prevent_destroy intentionally omitted. This is a reproducible sample environment
  # that is torn down and recreated; the filesystem holds no irreplaceable data (NEFF/HF
  # caches are regenerable). For a long-lived training cluster, set prevent_destroy = true.
}

# ---------------------------------------------------------------------------
# Security group for FSx — allow Lustre (988) from the EKS node CIDR
# ---------------------------------------------------------------------------
resource "aws_security_group" "fsx" {
  count       = var.fsx_enabled ? 1 : 0
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
# Version v1.9.0-eksbuild.1 confirmed.
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "fsx_csi_driver" {
  count = var.fsx_enabled ? 1 : 0
  # Reference module.eks output (not var.cluster_name) so the addon implicitly depends on the
  # cluster and never races its creation.
  cluster_name  = module.eks.cluster_name
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
  count = var.fsx_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "fsx-lustre"
    }
    provisioner   = "fsx.csi.aws.com"
    reclaimPolicy = "Retain"
    # Dynamic-provisioning parameters. This module creates ONE FSx filesystem in Terraform;
    # for that filesystem, bind a PVC statically via a PV (volumeHandle = its FS id). To let
    # the CSI driver create NEW filesystems per-PVC instead, drop fileSystemId below and keep
    # subnetId/securityGroupIds/deploymentType. The two models are mutually exclusive — this SC
    # references the Terraform-managed filesystem, so use it with a static PV.
    parameters = {
      subnetId         = module.vpc.private_subnets[0]
      securityGroupIds = aws_security_group.fsx[0].id
      deploymentType   = "PERSISTENT_2"
      fileSystemId     = aws_fsx_lustre_file_system.training[0].id
    }
  })

  depends_on = [aws_eks_addon.fsx_csi_driver]
}
