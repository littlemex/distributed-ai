# vpc-endpoints.tf
# VPC endpoints so the Karpenter controller (and other in-cluster AWS API callers) keep
# working even if the NAT gateway is gone or briefly unavailable.
#
# Discovered live: on `terraform destroy` with an accelerator node present, the NAT gateway
# (module.vpc, no ordering relationship with Karpenter) was removed while
# null_resource.wait_for_node_drain (karpenter.tf) was still polling for NodeClaims to drain.
# Karpenter's controller Pod runs in a private subnet and depends entirely on the NAT for
# internet-bound AWS API calls (EC2, STS, SSM, IAM) — the moment the NAT disappeared, every
# API call timed out, so the controller could never finish terminating the node/clearing its
# finalizer, and the drain-wait ran to its timeout. A module.vpc -> null_resource depends_on
# was not viable: null_resource.wait_for_node_drain's triggers reference module.eks.cluster_name,
# and module.eks depends on module.vpc's subnets, so that edge would be a dependency cycle.
# (IAM calls are only partially covered — see the note on locals.vpc_endpoint_services below.)
#
# Interface endpoints route these calls through the VPC network instead of the internet,
# independent of NAT gateway lifecycle. S3 (gateway endpoint, no hourly cost) is included
# because ECR image pulls resolve through S3-backed layers in some regions.
#
# IAM is deliberately NOT in this list: unlike EC2/STS/SSM, IAM has no regional Interface
# VPC endpoint service (it's a global service) — confirmed live via
# `aws ec2 describe-vpc-endpoint-services`, which lists ec2/ec2-fips/ssm*/sts/sts-fips but
# no iam entry. `aws_vpc_endpoint` creation for "com.amazonaws.<region>.iam" fails with
# InvalidServiceName. IAM calls (e.g. Karpenter's ListInstanceProfiles) still need the NAT
# or a working internet path.
locals {
  # ecr.api + ecr.dkr are required so private-subnet nodes can pull EKS-managed images
  # (VPC CNI / kube-proxy / EFA & GPU device plugins) without depending solely on NAT.
  # ecr.dkr fetches layers via the S3 gateway endpoint (defined separately below).
  # logs = CloudWatch Logs for node/pod logging.
  #
  # eks-auth is what makes EKS Pod Identity work without a NAT, and its absence is a
  # first-apply-only failure. Pod Identity does NOT authenticate through STS
  # AssumeRoleWithWebIdentity the way IRSA does: the Pod Identity Agent calls the EKS Auth API
  # (AssumeRoleForPodIdentity), a separate service principal from both sts and eks. Without
  # this endpoint, a Pod Identity consumer in a private subnet can only reach that API over the
  # NAT — and Terraform creates the NAT gateways in parallel with everything else, so on a
  # FRESH apply the aws-ebs-csi-driver addon can start before any NAT exists.
  #
  # Observed live on a from-scratch build (2026-08-02): the addon sat in CREATING for 17
  # minutes while its controller pods went CrashLoopBackOff with
  #   "dry-run EC2 API call failed: ... get credentials: failed to refresh cached credentials"
  # even though the IAM role, its trust policy, the Pod Identity association and the agent were
  # all present and correct — the VPC simply had zero NAT gateways at that point. An apply
  # against an already-built cluster never reproduces this, because the NAT is long since there.
  #
  # No extra ordering edge is needed once the endpoint exists: interface endpoints finish in
  # under a minute (45-55s measured) while the EKS control plane takes ~10 minutes, and addons
  # are created after the cluster, so eks-auth is always in place first. An earlier attempt to
  # force the ordering by routing module.eks's subnet_ids through a computed local made the
  # subnet ids unknown at plan time and cascaded into spurious replacements of Karpenter's IAM
  # policy attachments — do not reintroduce that.
  #
  # NAT still covers non-ECR registries (nvcr.io, quay.io, registry.k8s.io) and IAM (global
  # service, no interface endpoint — see the note above).
  vpc_endpoint_services = ["ec2", "sts", "ssm", "ecr.api", "ecr.dkr", "logs", "eks-auth"]
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.cluster_name}-vpc-endpoints"
  description = "Allow HTTPS from within the VPC to Interface VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from the VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.cluster_tags, {
    Name = "${var.cluster_name}-vpc-endpoints"
  })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.vpc_endpoint_services)

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.cluster_tags, {
    Name = "${var.cluster_name}-${each.value}"
  })
}

# Gateway endpoint (no hourly cost, no ENI) — associates with the private route tables so
# S3 traffic (ECR image layers, some SDK calls) does not need the NAT gateway either.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.cluster_tags, {
    Name = "${var.cluster_name}-s3"
  })
}
