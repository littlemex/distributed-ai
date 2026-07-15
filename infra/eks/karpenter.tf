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
#   featureGates (Chart values.yaml at v1.13.0 commit):
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

# Karpenter CRDs, installed as a SEPARATE chart. Helm never upgrades CRDs bundled in a
# chart's crds/ directory, so bumping var.karpenter_chart_version would otherwise leave the
# EC2NodeClass/NodePool/NodeClaim CRDs at their first-installed schema. Installing the
# dedicated karpenter-crd chart (same version) lets `helm upgrade` roll the CRD schema too.
resource "helm_release" "karpenter_crd" {
  namespace        = local.karpenter_namespace
  create_namespace = true
  name             = "karpenter-crd"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_chart_version

  repository_username = data.aws_ecrpublic_authorization_token.karpenter.user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter.password

  # The karpenter-crd chart can optionally run a conversion webhook; it is not needed here
  # (the controller chart runs its own), so disable it to avoid a second webhook Deployment.
  set {
    name  = "webhook.enabled"
    value = "false"
  }

  depends_on = [module.eks]
}

resource "helm_release" "karpenter" {
  namespace        = local.karpenter_namespace
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_chart_version
  # CRDs are managed by helm_release.karpenter_crd above, so the controller chart must not
  # also ship them.
  skip_crds = true
  # wait=false: controller readiness is not gated here. CRD REGISTRATION is guaranteed by
  # the explicit dependency on helm_release.karpenter_crd; the NodePool/EC2NodeClass
  # kubectl_manifest resources additionally depend on this release. Note: this orders
  # creation but does not itself wait for the CRDs to reach Established — a first apply can
  # occasionally need a re-apply if the API is momentarily slow to serve the new types.
  wait = false

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
    # Explicitly setting featureGates here is unnecessary.
    EOT
  ]

  depends_on = [
    module.eks,
    module.karpenter,
    helm_release.karpenter_crd,
  ]
}
