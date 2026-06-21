# Tenants (Future)

This directory is intentionally empty for now. It is where each **tenant** (a
team, customer, or project sharing the cluster) will get its isolated set of
Kubernetes and AWS resources.

## What multi-tenancy means here

Multiple independent workloads share one EKS cluster while staying isolated
from each other. Isolation is layered:

- **Namespace** per tenant — the basic Kubernetes boundary.
- **ResourceQuota / LimitRange** — caps CPU, memory, and object counts so one
  tenant cannot starve the others.
- **NetworkPolicy** — restricts pod-to-pod traffic so tenants cannot reach each
  other's pods by default.
- **RBAC Role/RoleBinding** — scopes each tenant's users to their namespace only.
- **Dedicated node group + taints/tolerations + nodeSelector** — optional hard
  isolation so a tenant's pods run on their own nodes.
- **IRSA role per tenant** — scoped AWS permissions for that tenant's workloads,
  trusting the cluster OIDC provider.

## How it will work

Each tenant will be one instance of a reusable Terraform module, e.g.:

```hcl
module "tenant_acme" {
  source            = "../modules/tenant"
  tenant_name       = "acme"
  cpu_quota         = "20"
  memory_quota      = "40Gi"
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
  # ...
}
```

Onboarding a new tenant is then a single new `module` block plus its variables —
the README's "Extending the platform" section walks through this end to end.

## State isolation options

- **One state for all tenants** (simplest): a single `tenants/terraform.tfstate`.
- **One state per tenant** (strongest isolation): key like
  `tenants/acme/terraform.tfstate`, so a mistake on one tenant cannot affect
  another's state.
