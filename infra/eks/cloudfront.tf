################################################################################
# CloudFront → ALB → EKS demo endpoint
#
# Architecture:
#   Client → CloudFront (HTTPS) → ALB (HTTP/80) → EKS Pod (echo-server)
#
# Security (defence in depth):
#   Layer 1 — ALB Security Group restricted to CloudFront managed prefix list
#              (com.amazonaws.global.cloudfront.origin-facing). Direct internet
#              access to the ALB is rejected at the network layer.
#   Layer 2 — X-Origin-Verify custom header. CloudFront sets the header; the
#              Ingress (kubectl_manifest.demo_ingress in this file) validates it
#              via alb.ingress.kubernetes.io/conditions. Even if the prefix list
#              allows traffic, requests without the correct header are dropped.
#   Note: CloudFront → ALB uses HTTP/80 (no ACM cert on ALB required for demo).
#         PRODUCTION: attach an ACM certificate to the ALB listener and set
#         origin_protocol_policy = "https-only". See README.md TODO section.
#
# Gated by var.enable_demo_app (default false) — see alb-controller.tf. The
# Namespace/Deployment/Service/Ingress in this file require enable_demo_app;
# the CloudFront distribution additionally requires enable_cloudfront.
#
# Two-phase deployment (var.enable_cloudfront, default = false):
#   Phase 1  enable_demo_app=true, enable_cloudfront=false (default):
#     terraform apply -var enable_demo_app=true
#     → ALB Controller + demo Namespace/Deployment/Service/Ingress are created.
#     → Wait until `kubectl get ingress -n demo` shows a non-empty ADDRESS.
#     → Confirm: curl http://<alb-dns>/ returns 200 (no header guard yet).
#   Phase 2  enable_cloudfront=true:
#     terraform apply -var enable_demo_app=true -var enable_cloudfront=true
#     → aws_lb data source resolves the ALB DNS.
#     → CloudFront distribution + ALB SG prefix-list rule + Ingress header
#       condition are applied atomically.
#     → Confirm: curl https://<cloudfront-domain>/ returns 200.
#                curl http://<alb-dns>/ times out (SG blocks direct access at
#                the network layer — this is a connection timeout, not a 403).
#
# To set permanently: add `enable_demo_app = true` (and `enable_cloudfront = true`
# for Phase 2) to terraform.tfvars.
#
# Rolling back Phase 2 → Phase 1 (enable_cloudfront true → false) removes
# aws_security_group.alb_cloudfront_only, but there is no explicit dependency forcing
# the Ingress's security-groups annotation update (which detaches the SG from the ALB)
# to land first — the SG delete can occasionally hit AWS's DependencyViolation and need
# a retry (Terraform retries automatically). If it doesn't clear, re-run apply/destroy.
################################################################################

# ── Guard: CloudFront-only resources in this file require enable_cloudfront=true ──
locals {
  cf_enabled = var.enable_cloudfront ? 1 : 0
}

# ── Origin-verify secret ──────────────────────────────────────────────────────
# Stored in Terraform state (encrypted if using S3 + KMS backend).
# Not committed to Git — value is injected into the Ingress via kubectl_manifest.

resource "random_password" "origin_verify" {
  count   = local.cf_enabled
  length  = 32
  special = false # alphanumeric only — safe in HTTP header values
}

# ── CloudFront managed cache / origin-request policies (name lookup) ─────────
# Avoid hardcoding managed policy UUIDs; resolve by name instead.

data "aws_cloudfront_cache_policy" "caching_disabled" {
  count = local.cf_enabled
  name  = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  count = local.cf_enabled
  name  = "Managed-AllViewer"
}

# ── CloudFront origin-facing managed prefix list ──────────────────────────────
# Used to restrict the ALB Security Group to CloudFront IPs only.
# Name is stable across all regions: com.amazonaws.global.cloudfront.origin-facing

data "aws_ec2_managed_prefix_list" "cloudfront_origin" {
  count = local.cf_enabled
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

# ── ALB discovery ─────────────────────────────────────────────────────────────
# Requires the ALB to exist (Phase 2 only). Guarded by local.cf_enabled.
# Tag cluster_name prevents matching ALBs from other clusters in the same account.

data "aws_lb" "demo_echo" {
  count = local.cf_enabled
  tags = {
    "Component"    = "demo-echo"
    "cluster-name" = var.cluster_name
  }
}

# ── ALB Security Group: restrict ingress to CloudFront prefix list ────────────
# A dedicated SG attached to the ALB via Ingress annotation
# (alb.ingress.kubernetes.io/security-groups). The ALB controller adds this SG
# alongside the SGs it manages. Direct internet access (non-CloudFront IPs) is
# blocked at the network layer before the header check.

resource "aws_security_group" "alb_cloudfront_only" {
  count       = local.cf_enabled
  name        = "${var.cluster_name}-alb-cloudfront-only"
  description = "Allow HTTP/80 inbound only from CloudFront origin-facing IPs. Attached to the demo-echo ALB."
  vpc_id      = module.vpc.vpc_id

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-alb-cloudfront-only"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  count             = local.cf_enabled
  security_group_id = aws_security_group.alb_cloudfront_only[0].id
  description       = "HTTP from CloudFront origin-facing prefix list only"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin[0].id
}

resource "aws_vpc_security_group_egress_rule" "alb_cloudfront_egress" {
  count             = local.cf_enabled
  security_group_id = aws_security_group.alb_cloudfront_only[0].id
  description       = "Unrestricted egress - ALB to pod health checks and traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# kubectl_manifest reports "destroyed" the moment the Kubernetes API accepts the delete
# request — it does not wait for the ALB Controller to finish its async finalizer cleanup
# (ingress.k8s.aws/resources removes the Ingress's backing ALB before letting the object
# disappear). Without a delay, destroying helm_release.alb_controller right after starting
# the Ingress delete orphans it in Terminating forever (the controller that would remove
# the finalizer is already gone). This resource sits between them so that, on destroy,
# Terraform tears down demo_ingress → waits out destroy_duration here → THEN removes
# alb_controller. Depends on alb_controller (not the reverse) specifically so destroy order
# is its dependency's reverse: alb_controller is destroyed only after this resource, and
# this resource only after demo_ingress (which depends on it below).
resource "time_sleep" "demo_ingress_finalizer" {
  count      = local.demo_app_enabled
  depends_on = [helm_release.alb_controller[0]]

  destroy_duration = "20s"
}

# ── Demo application: Namespace + Deployment + Service ────────────────────────
# Gated by var.enable_demo_app (Phase 1). The demo Pod is pinned to the CPU
# NodePool via nodeSelector — pair with var.cpu_nodepool_enabled = true, or it
# stays Pending indefinitely with no healthy Ingress target.
# The Ingress is managed here (in cloudfront.tf) via kubectl_manifest so that
# Terraform can inject the origin_verify secret without hardcoding it in YAML.
#
# Phase 1: Ingress has no header condition (ALB accepts all traffic — useful for
#          initial smoke test before CloudFront is provisioned).
# Phase 2: Ingress gains the conditions.echo annotation with the secret value,
#          AND the SG annotation restricts the ALB to CloudFront IPs.

resource "kubectl_manifest" "demo_namespace" {
  count = local.demo_app_enabled
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = var.demo_namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
  })
}

resource "kubectl_manifest" "demo_deployment" {
  count = local.demo_app_enabled
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "echo"
      namespace = var.demo_namespace
      labels    = { app = "echo" }
    }
    spec = {
      replicas = 2
      selector = { matchLabels = { app = "echo" } }
      template = {
        metadata = { labels = { app = "echo" } }
        spec = {
          # Pin to cpu NodePool (Karpenter node-role label)
          nodeSelector = { "node-role" = "cpu" }
          containers = [{
            name  = "echo"
            image = var.demo_app_image
            ports = [{ containerPort = 80 }]
            env   = [{ name = "PORT", value = "80" }]
            resources = {
              requests = { cpu = "100m", memory = "64Mi" }
              limits   = { cpu = "200m", memory = "128Mi" }
            }
            readinessProbe = {
              httpGet             = { path = "/", port = 80 }
              initialDelaySeconds = 5
              periodSeconds       = 10
            }
            livenessProbe = {
              httpGet             = { path = "/", port = 80 }
              initialDelaySeconds = 10
              periodSeconds       = 30
            }
          }]
        }
      }
    }
  })
  depends_on = [kubectl_manifest.demo_namespace[0]]
}

resource "kubectl_manifest" "demo_service" {
  count = local.demo_app_enabled
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "echo"
      namespace = var.demo_namespace
      labels    = { app = "echo" }
    }
    spec = {
      type     = "ClusterIP"
      selector = { app = "echo" }
      ports    = [{ name = "http", port = 80, targetPort = 80, protocol = "TCP" }]
    }
  })
  depends_on = [kubectl_manifest.demo_namespace[0]]
}

# ── Demo Ingress ──────────────────────────────────────────────────────────────
# Phase 1 (enable_cloudfront=false): no header condition, no SG restriction.
#   → ALB accepts all traffic; useful for confirming the echo path is alive.
# Phase 2 (enable_cloudfront=true): conditions.echo header check is applied,
#   AND the CloudFront-only SG is attached via security-groups annotation.
#   → Only CloudFront-originated requests with the correct secret pass through.
#
# Note on conditions.echo vs actions.echo:
#   When using the `conditions.*` annotation with a named service backend, the
#   ALB controller applies the condition to the rule it creates for that service.
#   The `actions.*` annotation is only needed when backend.service.name is set to
#   the action name (use-annotation pattern). Since we use the standard service
#   name here, actions.echo is omitted to avoid confusion.

resource "kubectl_manifest" "demo_ingress" {
  count = local.demo_app_enabled
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "echo"
      namespace = var.demo_namespace
      annotations = merge(
        {
          # ingressClassName is the current standard (kubernetes.io/ingress.class is deprecated)
          "alb.ingress.kubernetes.io/scheme"               = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"          = "ip"
          "alb.ingress.kubernetes.io/healthcheck-path"     = "/"
          "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"
          "alb.ingress.kubernetes.io/listen-ports"         = jsonencode([{ HTTP = 80 }])
          # Tag ALB so data.aws_lb can find it. cluster-name prevents multi-cluster ambiguity.
          "alb.ingress.kubernetes.io/tags" = join(",", [
            "Project=distributed-ai",
            "ManagedBy=terraform",
            "Component=demo-echo",
            "cluster-name=${var.cluster_name}",
          ])
        },
        # Phase 2 only: attach CloudFront-only SG + X-Origin-Verify header condition
        var.enable_cloudfront ? {
          # Restrict ALB inbound to CloudFront prefix list IPs (Layer 1 defence)
          "alb.ingress.kubernetes.io/security-groups"                     = aws_security_group.alb_cloudfront_only[0].id
          "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
          # Require X-Origin-Verify header set by CloudFront (Layer 2 defence)
          # Direct requests reaching the ALB without the correct header get the
          # ALB's default 404 rule; requests blocked by the SG (Layer 1) never
          # reach the ALB at all and time out instead.
          "alb.ingress.kubernetes.io/conditions.echo" = jsonencode([{
            field = "http-header"
            httpHeaderConfig = {
              httpHeaderName = "X-Origin-Verify"
              values         = [random_password.origin_verify[0].result]
            }
          }])
        } : {}
      )
    }
    spec = {
      ingressClassName = "alb"
      rules = [{
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "echo"
                port = { number = 80 }
              }
            }
          }]
        }
      }]
    }
  })
  depends_on = [
    kubectl_manifest.demo_service[0],
    time_sleep.demo_ingress_finalizer[0],
  ]
}

# ── CloudFront distribution ───────────────────────────────────────────────────
# Created only in Phase 2 (enable_cloudfront=true).
# The distribution uses CloudFront's default *.cloudfront.net certificate.
# PRODUCTION: attach an ACM certificate (us-east-1) and set a custom domain.
# See README.md for production hardening checklist.

resource "aws_cloudfront_distribution" "demo_echo" {
  count    = local.cf_enabled
  provider = aws.us_east_1 # CloudFront ACM/WAF integrations require us-east-1; harmless for distribution itself

  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "${var.cluster_name} demo echo (CloudFront → ALB → EKS)"
  default_root_object = ""

  # Optional WAF WebACL (GLOBAL scope, us-east-1). Set var.cloudfront_web_acl_id to enable.
  web_acl_id = var.cloudfront_web_acl_id != "" ? var.cloudfront_web_acl_id : null

  origin {
    domain_name = data.aws_lb.demo_echo[0].dns_name
    origin_id   = "alb-demo-echo"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB listener is HTTP/80
      # PRODUCTION: change to "https-only" after attaching ACM cert to ALB
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60
      origin_read_timeout      = 60
    }

    # X-Origin-Verify: ALB Ingress validates this header (conditions.echo above).
    # Value is sensitive; never appears in plan output (stored in TF state only).
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify[0].result
    }
  }

  # Default cache behavior: CachingDisabled + AllViewer (pass-through for demo)
  default_cache_behavior {
    target_origin_id         = "alb-demo-echo"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled[0].id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer[0].id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Default *.cloudfront.net TLS certificate — no custom domain required for demo
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(var.tags, {
    Name      = "${var.cluster_name}-demo-echo"
    Component = "demo-echo"
  })

  depends_on = [
    kubectl_manifest.demo_ingress[0],
    aws_security_group.alb_cloudfront_only,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cloudfront_domain_name" {
  description = "CloudFront distribution URL (only set when enable_cloudfront=true)."
  value       = var.enable_cloudfront ? "https://${aws_cloudfront_distribution.demo_echo[0].domain_name}/" : "(enable_cloudfront=false — run Phase 2 to create CloudFront)"
}

output "alb_dns_name" {
  description = <<-EOT
    Demo app ALB DNS. Direct HTTP access:
      enable_cloudfront=false → 200 (no restriction yet, Phase 1).
      enable_cloudfront=true  → connection times out (Layer 1 SG blocks non-CloudFront
                                 IPs before the request reaches the ALB; a request that
                                 does reach the ALB without the X-Origin-Verify header
                                 gets a 404 from the ALB's default rule).
  EOT
  value = (
    !var.enable_demo_app ? "(enable_demo_app=false — no ALB created)" :
    var.enable_cloudfront ? "http://${data.aws_lb.demo_echo[0].dns_name}/" :
    # data.aws_lb is itself gated on enable_cloudfront, so the DNS name isn't available
    # from Terraform state in Phase 1 even though the ALB already exists — read it from
    # the cluster instead.
    "(enable_cloudfront=false — run: kubectl get ingress -n ${var.demo_namespace} echo)"
  )
}

output "origin_verify_secret" {
  description = "X-Origin-Verify header value (sensitive). Only set when enable_cloudfront=true."
  value       = var.enable_cloudfront ? random_password.origin_verify[0].result : "(not yet created)"
  sensitive   = true
}
