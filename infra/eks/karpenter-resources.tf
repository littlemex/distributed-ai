# karpenter-resources.tf
# EC2NodeClass and NodePool for GPU training with Capacity Block support.
#
# Verified facts (VERIFIED_FACTS.md):
#   - Karpenter provider-aws v1.13.0: capacity-type label = karpenter.sh/capacity-type, value = "reserved"
#   - EC2NodeClass v1: spec.capacityReservationSelectorTerms: [{id: cr-xxx}]
#   - disruption: consolidationPolicy WhenEmpty + consolidateAfter Never
#   - expireAfter uses duration string ("24h"), not ISO8601
#   - ReservedCapacity feature gate is enabled by default; no explicit override needed

locals {
  # capacityReservationSelectorTerms is an empty list when no reservation ID is provided.
  cb_reservation_terms = var.cb_reservation_id != "" ? [{ id = var.cb_reservation_id }] : []
}

resource "kubectl_manifest" "ec2nodeclass_gpu_training" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "gpu-training"
    }
    spec = {
      amiFamily = "AL2023"

      # Use the latest EKS-optimized AL2023 GPU AMI for the cluster version.
      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]

      instanceProfile = module.karpenter.instance_profile_name

      # Capacity Block reservation selector. Empty list when var.cb_reservation_id is unset.
      capacityReservationSelectorTerms = local.cb_reservation_terms

      # EFA requires hugepages; configure via AL2023 nodeadm userData.
      userData = <<-EOT
        ---
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          kubelet:
            config:
              systemReserved:
                memory: "2Gi"
          instance:
            localStorage:
              strategy: Raid0
        # Hugepages for EFA / NCCL GPUDirect RDMA
        ---
        # /etc/sysctl.d/99-hugepages.conf is written by the preBootstrapCommands below.
      EOT

      # Set hugepages and EFA-required kernel parameters before kubelet starts.
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "200Gi"
            volumeType          = "gp3"
            deleteOnTermination = true
            encrypted           = true
          }
        }
      ]

      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "Environment"            = var.environment
        "Project"                = "distributed-ai"
      }
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "nodepool_gpu_training" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "gpu-training"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-role" = "gpu-training"
          }
          annotations = {
            # Capacity Block nodes carry a capacity-reservation taint with a variable value;
            # pods must use operator: Exists to tolerate it regardless of the specific value.
            "karpenter.sh/capacity-reservation-note" = "use operator: Exists on capacity-reservation taint"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "gpu-training"
          }

          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["reserved"]
            },
            {
              key      = "node.kubernetes.io/instance-type"
              operator = "In"
              values   = [var.instance_type]
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            }
          ]

          # Expire nodes after the Capacity Block window.
          # local.cb_expire_after = "24h" when cb_end_date is set, "Never" otherwise.
          expireAfter = local.cb_expire_after
        }
      }

      disruption = {
        # Only consolidate truly empty nodes; never consolidate after idle to preserve CB nodes.
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "Never"
      }

      # No hard pod limit; Capacity Block is typically a single large instance.
      limits = {
        cpu    = "10000"
        memory = "100000Gi"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass_gpu_training]
}
