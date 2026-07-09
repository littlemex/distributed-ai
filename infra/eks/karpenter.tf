################################################################################
# Karpenter Helm release — v1.13.0
#
# Verified facts:
#   OCI chart repo  : oci://public.ecr.aws/karpenter/karpenter  (upstream docs)
#   Helm chart tag  : 1.13.0
#   ECR public auth : must be fetched from us-east-1 (AWS requirement for ECR Public)
#   Namespace       : "karpenter"  (locals.tf: karpenter_namespace = "karpenter")
#   Auth method     : Pod Identity (created by module.karpenter in iam.tf)
#                     — no IRSA serviceAccount annotation needed
#
#   featureGates (Chart values.yaml at v1.13.0 commit + VERIFIED_FACTS.md):
#     reservedCapacity         = true   BETA default — no override needed
#     nodeRepair               = false  ALPHA default
#     nodeOverlay              = false  ALPHA default
#     spotToSpotConsolidation  = false  ALPHA default
#     staticCapacity           = false  ALPHA default
#   → featureGates block omitted; defaults are correct.
#
#   interruptionQueue : module.karpenter.queue_name  (SQS queue from iam.tf)
#
# NOTE: Requires a provider alias `aws.us_east_1` in providers.tf (separate file):
#   provider "aws" {
#     alias  = "us_east_1"
#     region = "us-east-1"
#   }
################################################################################

# ECR public auth token must always come from us-east-1 (AWS API restriction)
data "aws_ecrpublic_authorization_token" "karpenter" {
  provider = aws.us_east_1
}

resource "helm_release" "karpenter" {
  namespace        = local.karpenter_namespace
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.13.0"
  wait             = false

  # ECR public OCI registries require credentials even for public images
  repository_username = data.aws_ecrpublic_authorization_token.karpenter.user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter.password

  values = [
    <<-EOT
    # Run Karpenter on the stable system node group, not on nodes it manages
    nodeSelector:
      karpenter.sh/controller: "true"

    # Required when running on a VPC with custom DNS / non-cluster-aware resolvers
    dnsPolicy: Default

    # Pod Identity is configured in iam.tf via module.karpenter.
    # No serviceAccount.annotations (IRSA) needed.

    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      # SQS queue for spot interruption, rebalance, and AWS health events
      interruptionQueue: ${module.karpenter.queue_name}

    # featureGates: all v1.13.0 defaults are correct
    #   reservedCapacity=true (BETA, enabled by default — ReservedCapacity CB support)
    #   nodeRepair=false, nodeOverlay=false, spotToSpotConsolidation=false, staticCapacity=false
    # Explicitly setting featureGates here is unnecessary and suppressed per VERIFIED_FACTS.md.
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
  ]
}
