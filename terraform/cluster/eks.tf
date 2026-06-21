# ==============================================================================
# CLUSTER: EKS Control Plane + Baseline Node Group + Core Add-ons
# ==============================================================================
# This uses the official terraform-aws-modules/eks module, which is the de-facto
# standard. It creates the control plane, the IAM roles, the OIDC provider (for
# IRSA), security groups, the baseline managed node group, and the core add-ons.
# ==============================================================================

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  # ---- API endpoint exposure ----
  cluster_endpoint_public_access       = var.endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  # Private access is always on so in-VPC nodes talk to the API over the
  # private network even when public access is also enabled.
  cluster_endpoint_private_access = true

  # ---- Where the cluster lives ----
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets # Worker nodes go in private subnets.

  # ---- IRSA: IAM Roles for Service Accounts ----
  # Creates an OIDC provider so individual Kubernetes service accounts can
  # assume narrowly-scoped IAM roles instead of giving nodes broad permissions.
  # This is essential for least-privilege and for add-ons like the EBS CSI driver.
  enable_irsa = true

  # ---- Core EKS-managed add-ons ----
  # Managed add-ons are maintained/patched by AWS. coredns and kube-proxy run on
  # nodes, so they are configured to wait until the node group is ready.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      # Run the CNI before nodes join so pod networking is ready immediately.
      before_compute = true
    }
    # The EBS CSI driver lets PersistentVolumeClaims provision EBS volumes.
    # It uses IRSA (the role created below) rather than node permissions.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # ---- Defaults applied to every managed node group ----
  eks_managed_node_group_defaults = {
    # AL2023 is the current recommended EKS-optimized OS.
    ami_type = "AL2023_x86_64_STANDARD"
  }

  # ---- The single BASELINE / SYSTEM node group ----
  # Deliberately minimal: just enough to host core add-ons. Application and
  # per-tenant capacity is added later in separate directories (see README).
  eks_managed_node_groups = {
    system = {
      instance_types = var.system_node_instance_types

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      # A label so you can target system workloads to these nodes.
      labels = {
        role = "system"
      }

      # A taint so ONLY workloads that explicitly tolerate it land here. This
      # keeps the baseline nodes reserved for system components and prevents
      # tenant workloads from accidentally scheduling onto them.
      taints = {
        dedicated = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # ---- Cluster access management ----
  # The modern EKS access-entry API (replaces the old aws-auth configmap).
  # The principal running Terraform is granted admin so the pipeline can manage
  # the cluster. authentication_mode API_AND_CONFIG_MAP keeps backward compat.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Grant any additional admin roles passed in via variable.
  access_entries = {
    for idx, arn in var.cluster_admin_role_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = {
    Cluster = local.cluster_name
  }
}

# ------------------------------------------------------------------------------
# IRSA role for the EBS CSI driver add-on.
# ------------------------------------------------------------------------------
# A purpose-built helper module that creates the IAM role + trust policy tying
# the EBS CSI driver's service account to AWS permissions for managing volumes.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}
