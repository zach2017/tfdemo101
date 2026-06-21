# ==============================================================================
# CLUSTER: VPC and Networking
# ==============================================================================
# EKS requires a VPC with both public and private subnets tagged in a specific
# way so that the AWS Load Balancer Controller and EKS can discover them.
# We use the community-standard terraform-aws-modules/vpc module rather than
# hand-writing dozens of subnet/route/gateway resources.
# ==============================================================================

# Look up the list of availability zones available in the chosen region so we
# never hardcode AZ names (which differ per account/region).
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The unique cluster name reused across resources and tags.
  cluster_name = "${var.project_name}-${var.environment}"

  # Pick the first N AZs from whatever the region offers.
  azs = slice(data.aws_availability_zones.available.names, 0, var.availability_zones_count)

  # Carve the VPC CIDR into private and public subnet ranges, one per AZ.
  # cidrsubnet() splits a network into smaller blocks deterministically.
  # Private subnets get the first blocks; public subnets are offset by +48.
  private_subnets = [for i in range(var.availability_zones_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.availability_zones_count) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${local.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # NAT gateway lets nodes in PRIVATE subnets reach the internet (to pull
  # container images, talk to AWS APIs) without being publicly reachable.
  # single_nat_gateway = true saves money in dev. For prod set it to false so
  # each AZ has its own NAT gateway (HA, but ~3x the cost).
  enable_nat_gateway   = true
  single_nat_gateway   = var.environment != "prod"
  one_nat_gateway_per_az = var.environment == "prod"

  # DNS support is required for EKS service discovery to work.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # ---- Subnet tags that EKS and the Load Balancer Controller rely on ----
  # Public subnets get this tag so internet-facing load balancers land here.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  # Private subnets get this tag so internal load balancers land here, and so
  # the cluster knows nodes/pods live here.
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}
