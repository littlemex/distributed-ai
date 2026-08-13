################################################################################
# Provider configuration
#
# This bootstrap module is a standalone root module and intentionally uses local
# state: it creates the bucket and lock table that the parent infra/eks working
# directory may later migrate into.
################################################################################

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}
