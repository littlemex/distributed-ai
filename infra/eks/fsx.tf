# fsx.tf
# FSx for Lustre — single-AZ, high-throughput scratch/checkpoint filesystem. This is the fast
# scratch layer of the default two-layer storage set (Lustre scratch here + OpenZFS NFS home
# in openzfs.tf), mirroring awsome-distributed-ai. ON by default (var.fsx_enabled): the
# distributed-training samples cannot run without a shared high-throughput volume.
# prevent_destroy is intentionally NOT set so the environment stays destroyable; teardown
# deletes the filesystem and its data (regenerable caches). Set prevent_destroy = true for a
# long-lived cluster holding irreplaceable data.
#
# CSI-driver DECOUPLING: the aws-fsx-csi-driver add-on and its IAM role are created
# UNCONDITIONALLY — a CSI driver is a permanent cluster capability, independent of whether an
# FSx filesystem currently exists. var.fsx_enabled gates ONLY the filesystem, its security
# groups, and the static PV below. (Same decoupling as efs.tf.)
#
# Static provisioning only (mirrors efs.tf): Terraform creates ONE filesystem and a
# PersistentVolume with a fixed volumeHandle. There is no dynamic-provisioning StorageClass
# here — aws-fsx-csi-driver does not support binding a StorageClass to an EXISTING
# filesystem via a "fileSystemId" parameter (that key is not read by the driver; a PVC
# against such a StorageClass would either error or silently provision an unwanted second
# multi-TB filesystem). See https://github.com/kubernetes-sigs/aws-fsx-csi-driver/issues/400.
#
# Notes:
#   - aws-fsx-csi-driver EKS addon: var.fsx_csi_driver_version (default v1.9.0-eksbuild.1)
#   - region and account are taken from the configured AWS provider

# Lustre LNET ports (AWS-fixed protocol values, not tunable). Defined once here so the six
# SG rules below reference them instead of repeating the literals — a mistyped port in one of
# six rules would silently break the bidirectional requirement CreateFileSystem validates.
# See https://docs.aws.amazon.com/fsx/latest/LustreGuide/limit-access-security-groups.html
locals {
  fsx_lustre_port           = 988
  fsx_lustre_high_port_from = 1018
  fsx_lustre_high_port_to   = 1023
}

# ---------------------------------------------------------------------------
# FSx for Lustre file system
# ---------------------------------------------------------------------------
resource "aws_fsx_lustre_file_system" "training" {
  count = var.fsx_enabled ? 1 : 0
  # Single-AZ placement — must match var.fsx_subnet_index (default 0 = private_subnets[0]).
  # Keep this aligned with whichever accelerator pool's `zone` will use this filesystem: a
  # cross-AZ mount within the same VPC works but incurs inter-AZ data-transfer charges and
  # added latency, so co-locating the pool and the filesystem in one AZ is preferred.
  subnet_ids = [module.vpc.private_subnets[var.fsx_subnet_index]]

  security_group_ids = [aws_security_group.fsx[0].id]

  # PERSISTENT_2 supports SSD storage and is required for data repository associations.
  deployment_type = "PERSISTENT_2"

  # PERSISTENT_2 SSD supports 125/250/500/1000 MB/s/TiB (125 is the minimum). Required by
  # the FSx API for PERSISTENT_1/PERSISTENT_2 — the driver/provider do not default it.
  per_unit_storage_throughput = var.fsx_per_unit_storage_throughput

  # Storage capacity must be a multiple of 2400 GiB for PERSISTENT_2 SSD.
  storage_capacity = var.fsx_storage_capacity_gib

  storage_type = "SSD"

  # EFA (opt-in, var.fsx_efa_enabled): OS-bypass RDMA over SRD for up to 700 Gbps/client
  # (1200 with GPUDirect Storage) vs 100 Gbps over TCP. EFA can only be set at create time,
  # so toggling this replaces the filesystem. It requires USER_PROVISIONED metadata with
  # >= 6000 IOPS (an EFA API requirement); when EFA is off we omit metadata_configuration
  # entirely so FSx auto-provisions it from capacity. az.tf preconditions enforce the
  # >= 4800 GiB / >= 6000 IOPS minimums when EFA is on. The CLIENT side (EFA driver + Lustre
  # client + LNET/EFA config on the node, EFA-capable instance) is NOT set up by this module
  # — see the Basic10 chapter. dynamic{} renders zero blocks when EFA is off, keeping the
  # default TCP filesystem byte-identical to the pre-EFA config.
  #
  # Use `? true : null` (not `? true : false`) so that when EFA is off the attribute is
  # UNSET, not explicitly false. efa_enabled is ForceNew; a filesystem created by an older
  # provider carries null in state, and an explicit `= false` in config could be read as a
  # change and propose a replacement. null means "exactly as if we never wrote it", so an
  # existing TCP filesystem plans as no-op regardless of how it was originally created.
  efa_enabled = var.fsx_efa_enabled ? true : null

  dynamic "metadata_configuration" {
    for_each = var.fsx_efa_enabled ? [1] : []
    content {
      mode = "USER_PROVISIONED"
      iops = var.fsx_metadata_iops
    }
  }

  # Lustre-specific configuration.
  data_compression_type = "LZ4"

  tags = {
    Name        = "${var.cluster_name}-fsx-lustre"
    Environment = var.environment
    Project     = "distributed-ai"
  }

  # FSx validates at CreateFileSystem time that the attached security group already permits
  # Lustre LNET traffic on port 988 (and the 1018-1023 high ports). depends_on alone only
  # orders the API CALLS — it does not wait for the SG rules to PROPAGATE to the FSx network
  # validation service, so a create issued immediately after the rule APIs return can still
  # get InvalidNetworkSettings (observed: first apply failed, re-apply succeeded). The
  # time_sleep below adds a propagation delay so the first apply is deterministic, not
  # "idempotent but probabilistic on the first try".
  depends_on = [time_sleep.fsx_sg_propagation]

  # NOTE: prevent_destroy intentionally omitted. This is a reproducible sample environment
  # that is torn down and recreated; the filesystem holds no irreplaceable data (NEFF/HF
  # caches are regenerable). For a long-lived training cluster, set prevent_destroy = true.
}

# ---------------------------------------------------------------------------
# Security groups for FSx <-> EKS node Lustre traffic.
#
# AWS's FSx for Lustre security-group guide requires rules on BOTH sides, by security-group
# ID rather than CIDR — SGs being stateful does not cover this traffic pattern, and a
# CIDR-based rule (even 0.0.0.0/0) does not satisfy AWS's own documented requirement:
# https://docs.aws.amazon.com/fsx/latest/LustreGuide/limit-access-security-groups.html
# ---------------------------------------------------------------------------
resource "aws_security_group" "fsx" {
  count       = var.fsx_enabled ? 1 : 0
  name        = "${var.cluster_name}-fsx-sg"
  description = "Lustre traffic between the FSx file system and EKS node clients"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name        = "${var.cluster_name}-fsx-sg"
    Environment = var.environment
  }
}

# AWS's CreateFileSystem network check requires the FSx security group to permit Lustre LNET
# traffic from ITSELF (the FSx ENIs and Lustre clients that share this SG talk to each other on
# 988 + 1018-1023). Without these self-referencing rules CreateFileSystem returns
# InvalidNetworkSettings ("...do not permit Lustre LNET network traffic on port 988") even though
# the node<->fsx rules below are present. See
# https://docs.aws.amazon.com/fsx/latest/LustreGuide/limit-access-security-groups.html
resource "aws_vpc_security_group_ingress_rule" "fsx_self_988" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = aws_security_group.fsx[0].id
  description                  = "Lustre port 988 within the FSx security group (self-referencing)"
  from_port                    = local.fsx_lustre_port
  to_port                      = local.fsx_lustre_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.fsx[0].id
}

resource "aws_vpc_security_group_ingress_rule" "fsx_self_high_ports" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = aws_security_group.fsx[0].id
  description                  = "Lustre high ports 1018-1023 within the FSx security group (self-referencing)"
  from_port                    = local.fsx_lustre_high_port_from
  to_port                      = local.fsx_lustre_high_port_to
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.fsx[0].id
}

resource "aws_vpc_security_group_ingress_rule" "fsx_from_nodes_988" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = aws_security_group.fsx[0].id
  description                  = "Lustre port 988 from EKS nodes"
  from_port                    = local.fsx_lustre_port
  to_port                      = local.fsx_lustre_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_ingress_rule" "fsx_from_nodes_high_ports" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = aws_security_group.fsx[0].id
  description                  = "Lustre high ports 1018-1023 from EKS nodes"
  from_port                    = local.fsx_lustre_high_port_from
  to_port                      = local.fsx_lustre_high_port_to
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.node_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "fsx_egress_all" {
  count             = var.fsx_enabled ? 1 : 0
  security_group_id = aws_security_group.fsx[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# EFA (SRD) traffic is OS-bypass and not expressible as TCP port rules, so AWS requires the
# EFA-enabled filesystem's security group to allow ALL traffic to/from ITSELF (self-referencing
# all-protocols ingress; egress is already all via fsx_egress_all). This is a separate
# requirement from the Lustre 988/1018-1023 port rules above and is only needed when EFA is on.
# See the FSx for Lustre EFA workshop (4-5) and efa-file-systems docs.
#
# INCOMPLETE ON ITS OWN: a self-referencing rule only permits traffic between ENIs that are
# MEMBERS of this SG. The FSx ENIs are, but this cluster's nodes use module.eks
# node_security_group_id / the NCCL efa_node SG — they are NOT in this SG. So SRD traffic
# node<->FSx does not flow until the client's EFA interface is either put in this SG or given
# a mutual all-traffic rule with it. This module does NOT wire that up (it only prepares the
# filesystem side); the node-side EFA/LNET setup and this SG membership must be added together
# when enabling EFA end to end. See the Basic10 chapter.
#
# EFA is also single-AZ: with fsx_efa_enabled the client accelerator pool's zone MUST equal
# this filesystem's AZ (var.fsx_subnet_index), since EFA/SRD cannot cross AZs — a cross-AZ
# mount that merely "works with inter-AZ charges" over TCP does not apply to the EFA path.
resource "aws_vpc_security_group_ingress_rule" "fsx_self_efa_all" {
  count                        = var.fsx_enabled && var.fsx_efa_enabled ? 1 : 0
  security_group_id            = aws_security_group.fsx[0].id
  description                  = "All traffic within the FSx security group for EFA/SRD (self-referencing)"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.fsx[0].id
}

# Propagation delay so the FSx security-group rules above are visible to the FSx network
# validation service before CreateFileSystem runs (see the comment on the filesystem's
# depends_on). 30s is empirically enough; it only runs on first create (create_duration is
# not re-triggered unless the triggers change).
resource "time_sleep" "fsx_sg_propagation" {
  count           = var.fsx_enabled ? 1 : 0
  create_duration = "30s"

  # Re-run the propagation wait whenever EFA is toggled. Enabling EFA on an existing cluster
  # replaces the filesystem AND adds the self-referencing EFA SG rule; without a trigger the
  # sleep is already created and does not re-fire, so CreateFileSystem can run before the new
  # rule propagates to the FSx network-validation service and fail on the first apply.
  triggers = {
    fsx_efa_enabled = tostring(var.fsx_efa_enabled)
  }

  depends_on = [
    aws_vpc_security_group_ingress_rule.fsx_self_988,
    aws_vpc_security_group_ingress_rule.fsx_self_high_ports,
    aws_vpc_security_group_ingress_rule.fsx_from_nodes_988,
    aws_vpc_security_group_ingress_rule.fsx_from_nodes_high_ports,
    aws_vpc_security_group_egress_rule.fsx_egress_all,
    aws_vpc_security_group_ingress_rule.fsx_self_efa_all,
  ]
}

# Client-side (EKS node) rules — the other half of the bidirectional requirement above.
# module.eks.node_security_group_id is the EKS-managed node SG; these rules are added here
# rather than in vpc.tf/eks.tf because they only apply when var.fsx_enabled.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_fsx_988" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = module.eks.node_security_group_id
  description                  = "Lustre port 988 from the FSx file system"
  from_port                    = local.fsx_lustre_port
  to_port                      = local.fsx_lustre_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.fsx[0].id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_fsx_high_ports" {
  count                        = var.fsx_enabled ? 1 : 0
  security_group_id            = module.eks.node_security_group_id
  description                  = "Lustre high ports 1018-1023 from the FSx file system"
  from_port                    = local.fsx_lustre_high_port_from
  to_port                      = local.fsx_lustre_high_port_to
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.fsx[0].id
}

# ---------------------------------------------------------------------------
# IAM role for EKS Pod Identity (mirrors the EFS/EBS CSI pattern in efs.tf/iam.tf).
# Created unconditionally (permanent infra): the driver is installed whether or not an FSx
# filesystem exists. fsx:DescribeFileSystems is the only call the driver makes for static
# provisioning (CreateFileSystem/DeleteFileSystem/UpdateFileSystem are dynamic-provisioning-
# only code paths, never exercised by a fixed-volumeHandle PV) — FSx does not support
# ARN-scoped resource permissions, so this is Resource "*" regardless.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "fsx_csi_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "fsx_csi" {
  name               = "${var.cluster_name}-fsx-csi"
  assume_role_policy = data.aws_iam_policy_document.fsx_csi_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "fsx_csi_describe" {
  statement {
    actions   = ["fsx:DescribeFileSystems"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fsx_csi_describe" {
  name   = "fsx-describe"
  role   = aws_iam_role.fsx_csi.id
  policy = data.aws_iam_policy_document.fsx_csi_describe.json
}

# ---------------------------------------------------------------------------
# aws-fsx-csi-driver EKS addon — installed unconditionally (permanent infra).
# ---------------------------------------------------------------------------
resource "aws_eks_addon" "fsx_csi_driver" {
  # Reference module.eks output (not var.cluster_name) so the addon implicitly depends on the
  # cluster and never races its creation.
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-fsx-csi-driver"
  addon_version = var.fsx_csi_driver_version

  pod_identity_association {
    role_arn        = aws_iam_role.fsx_csi.arn
    service_account = "fsx-csi-controller-sa"
  }

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Environment = var.environment
    Project     = "distributed-ai"
  }

  # See the identical comment on aws_eks_addon.efs_csi_driver in efs.tf.
  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Static PV for the Terraform-managed filesystem (mirrors efs_neuron_workspace_pv in
# efs.tf). No StorageClass: a PVC binds directly to this PV by name (claimRef) or by
# matching accessModes/capacity with volumeName unset. Static (empty storageClassName)
# so no dynamic provisioner ever races it.
# ---------------------------------------------------------------------------
resource "kubectl_manifest" "fsx_training_pv" {
  count = var.fsx_enabled ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata   = { name = "fsx-training" }
    spec = {
      capacity                      = { storage = "${var.fsx_storage_capacity_gib}Gi" }
      volumeMode                    = "Filesystem"
      accessModes                   = ["ReadWriteMany"]
      persistentVolumeReclaimPolicy = "Retain"
      # Empty storageClassName marks this a statically-provisioned PV — see the comment on
      # the analogous EFS PV in efs.tf for why this must not reference a StorageClass name.
      storageClassName = ""
      mountOptions     = ["flock"]
      csi = {
        driver       = "fsx.csi.aws.com"
        volumeHandle = aws_fsx_lustre_file_system.training[0].id
        # Required for static provisioning: the node plugin mounts "<dnsname>@tcp:/<mountname>"
        # and does not derive either value from volumeHandle alone (volumeHandle is only used
        # as the Kubernetes-side volume identifier, not resolved back to a filesystem via an
        # AWS API call at mount time). BOTH keys are lowercase: aws-fsx-csi-driver reads
        # "dnsname" (not "dnsName") — a camelCase key is silently ignored and NodeStageVolume
        # fails with "dnsname is not provided", leaving the pod stuck in ContainerCreating.
        volumeAttributes = {
          dnsname   = aws_fsx_lustre_file_system.training[0].dns_name
          mountname = aws_fsx_lustre_file_system.training[0].mount_name
        }
      }
    }
  })

  depends_on = [aws_eks_addon.fsx_csi_driver]
}
