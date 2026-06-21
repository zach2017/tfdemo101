# Node Groups (Future)

This directory is intentionally empty for now. It is where you will add
**additional EKS managed node groups** beyond the baseline `system` group that
ships in `terraform/cluster`.

## Why node groups live in their own directory

Separating node groups from the cluster keeps blast radius small. Adding,
resizing, or replacing a node group should never risk the control plane or the
networking. Each concern gets its own state file and its own pipeline trigger.

## How it will work

1. This directory will have its own backend with a distinct state key, e.g.
   `node-groups/terraform.tfstate`.
2. It will read the cluster's outputs (cluster name, subnet IDs, node security
   group, OIDC provider ARN) using a `terraform_remote_state` data source:

   ```hcl
   data "terraform_remote_state" "cluster" {
     backend = "s3"
     config = {
       bucket = "eks-platform-tfstate-123456789012"
       key    = "cluster/terraform.tfstate"
       region = "us-east-1"
     }
   }
   ```

3. New node groups attach to the existing cluster by referencing
   `data.terraform_remote_state.cluster.outputs.cluster_name`, etc.

## Adding a node group

Define a reusable local map of node-group specs (instance types, sizes, labels,
taints) and loop over it. A new GPU pool or a memory-optimized pool becomes a
few lines added to that map — no copy-paste of resource blocks.

See the root `README.md` section "Extending the platform" for the full pattern.
