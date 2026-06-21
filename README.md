# EKS Platform — Terraform + GitHub Actions 

A production-minded starting point for provisioning an **Amazon EKS** cluster
with **Terraform**, deployed through a **GitHub Actions** pipeline. This repo
focuses *only* on the cluster foundation. Additional **node groups** and
**multi-tenant** resources get their own sibling directories later, so you can
grow the platform without ever putting the control plane at risk.

---

## Table of contents

1. [What is EKS?](#1-what-is-eks)
2. [What is Terraform, and why use it in a pipeline?](#2-what-is-terraform-and-why-use-it-in-a-pipeline)
3. [Repository structure](#3-repository-structure)
4. [Architecture of what gets built](#4-architecture-of-what-gets-built)
5. [Prerequisites](#5-prerequisites)
6. [One-time setup](#6-one-time-setup)
7. [The Terraform files, explained](#7-the-terraform-files-explained)
8. [The GitHub Actions pipeline, explained](#8-the-github-actions-pipeline-explained)
9. [Day-to-day: how to make changes](#9-day-to-day-how-to-make-changes)
10. [Extending the platform: node groups & tenants](#10-extending-the-platform-node-groups--tenants)
11. [Troubleshooting](#11-troubleshooting)

---

## 1. What is EKS?

**Amazon Elastic Kubernetes Service (EKS)** is AWS's managed Kubernetes
offering. Kubernetes is the open-source system for running containerized
applications across a fleet of machines — it handles scheduling containers onto
servers, restarting them when they crash, scaling them up and down, and giving
them stable networking and storage.

A Kubernetes cluster has two parts:

- The **control plane** — the "brain" (the API server, scheduler, and the
  database `etcd` that stores cluster state). With EKS, **AWS runs and patches
  the control plane for you** across multiple Availability Zones. You never SSH
  into it; you just talk to its API.
- The **data plane** — the **worker nodes** (EC2 instances) where your actual
  containers run. You own these. In this repo they are created as an EKS
  **managed node group**, which means AWS handles the heavy lifting of
  provisioning and gracefully rolling them during updates.

Why EKS instead of plain Kubernetes on EC2? You offload the hardest, most
safety-critical part (the control plane) to AWS, you get native integration
with AWS IAM, VPC networking, load balancers, and EBS storage, and you get a
conformant Kubernetes API so standard tooling just works.

**Key EKS concepts this repo uses:**

- **Managed node group** — a set of EC2 worker nodes whose lifecycle EKS
  manages. You declare instance type and min/max/desired counts; EKS does the
  rest.
- **Add-ons** — AWS-maintained versions of core cluster components: `vpc-cni`
  (pod networking), `coredns` (in-cluster DNS), `kube-proxy` (service
  routing), and the `aws-ebs-csi-driver` (persistent volumes on EBS).
- **IRSA (IAM Roles for Service Accounts)** — lets an individual Kubernetes
  workload assume a narrowly-scoped IAM role instead of granting broad
  permissions to the whole node. This is the backbone of least-privilege on
  EKS and of safe multi-tenancy.
- **Access entries** — the modern way to grant IAM principals (users/roles)
  permissions inside the cluster, replacing the older `aws-auth` ConfigMap.

---

## 2. What is Terraform, and why use it in a pipeline?

**Terraform** is an open-source **Infrastructure as Code (IaC)** tool. Instead
of clicking around the AWS Console to create a VPC, a cluster, and node groups,
you *describe the desired end state* in declarative configuration files
(`.tf`). Terraform compares that desired state to reality and computes the
exact set of create/update/delete actions needed to reconcile them.

Core Terraform vocabulary:

- **Resource** — one piece of infrastructure (`aws_s3_bucket`,
  `aws_dynamodb_table`). You declare what you want; Terraform makes the API
  calls.
- **Module** — a reusable, parameterized bundle of resources. This repo leans
  on the official `terraform-aws-modules/vpc` and `terraform-aws-modules/eks`
  modules, which encode hundreds of best-practice details so you don't have to
  hand-write them.
- **Provider** — a plugin that knows how to talk to a specific API (the `aws`
  provider, the `kubernetes` provider).
- **State** — a file (`terraform.tfstate`) that records what Terraform has
  created and maps your config to real resource IDs. **State is the source of
  truth Terraform diffs against.**
- **Plan** — a preview ("here is exactly what I will change"). **Apply** — the
  step that actually makes those changes.

**Why run Terraform in a pipeline (GitHub Actions) instead of from a laptop?**

- **One source of truth.** Infrastructure changes go through Git. The repo's
  `main` branch always reflects what is deployed.
- **Review before reality.** Every change opens a Pull Request; the pipeline
  posts the `terraform plan` as a PR comment so a human reviews the diff
  *before* anything changes in AWS.
- **Consistency & no "works on my machine."** The same pinned Terraform
  version and the same credentials path run every time.
- **No shared secrets.** With **OIDC**, GitHub authenticates to AWS by
  assuming an IAM role for the duration of a job. There are **no long-lived AWS
  access keys** stored in GitHub.
- **Safe concurrency.** Remote **state locking** (via DynamoDB) prevents two
  runs from corrupting state by writing simultaneously.
- **Auditability.** Who changed what, when, and the exact plan are all
  recorded in Git history and the Actions logs.

---

## 3. Repository structure

```
.
├── .github/
│   └── workflows/
│       ├── cluster.yml          # Plan on PR, apply on main — for the cluster
│       └── lint.yml             # tflint + Trivy security scan on every PR
├── terraform/
│   ├── bootstrap/               # Creates the S3+DynamoDB backend (run ONCE)
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   ├── cluster/                 # THE EKS CLUSTER (focus of this repo)
│   │   ├── backend.tf           # Where state is stored
│   │   ├── providers.tf         # aws + kubernetes providers
│   │   ├── variables.tf         # All tunable inputs
│   │   ├── vpc.tf               # VPC, subnets, NAT, EKS subnet tags
│   │   ├── eks.tf               # Control plane, system node group, add-ons
│   │   ├── outputs.tf           # Values consumed by node-groups/tenants
│   │   └── terraform.tfvars.example
│   ├── node-groups/             # FUTURE: extra worker pools (placeholder)
│   │   └── README.md
│   └── tenants/                 # FUTURE: per-tenant isolation (placeholder)
│       └── README.md
├── .gitignore
├── .tflint.hcl
└── README.md                    # You are here
```

**Why this layout?** Each directory is an independent Terraform *root* with its
own state file. The cluster, the node groups, and the tenants therefore change
independently. A risky tenant change can never accidentally touch the control
plane, because they don't share state and the pipeline only runs the directory
that changed. This is the single most important structural decision in the repo.

---

## 4. Architecture of what gets built

Running the `cluster` directory produces:

- A **VPC** spanning 3 Availability Zones, each with a **public** subnet
  (for internet-facing load balancers) and a **private** subnet (for worker
  nodes). A **NAT gateway** lets private nodes reach the internet outbound to
  pull images, while keeping them unreachable from the internet inbound.
- An **EKS control plane** (managed by AWS) at the chosen Kubernetes version.
- One small **`system` managed node group** running in the private subnets,
  **tainted** so only core add-ons schedule there. Application and tenant
  capacity is added later in the other directories.
- Core **add-ons**: `vpc-cni`, `coredns`, `kube-proxy`, `aws-ebs-csi-driver`.
- An **OIDC provider** enabling **IRSA**, plus the IRSA role the EBS CSI driver
  uses.
- **Access entries** granting the pipeline role (and any roles you list)
  cluster-admin.

The **bootstrap** directory, run once beforehand, produces the **S3 bucket**
(versioned + encrypted) that stores Terraform state and the **DynamoDB table**
that locks it.

---

## 5. Prerequisites

- An **AWS account** and permissions to create IAM, VPC, and EKS resources.
- **Terraform ≥ 1.9** and the **AWS CLI** installed locally (only needed for
  the one-time bootstrap and for `kubectl` access; day-to-day changes go
  through the pipeline).
- **`kubectl`** to talk to the cluster after creation.
- A **GitHub repository** to host this code.
- An **IAM OIDC identity provider for GitHub** plus an **IAM role** the
  pipeline assumes (created in setup below).

---

## 6. One-time setup

### Step 1 — Create the state backend (bootstrap)

The pipeline stores state in S3, so that bucket must exist first. Run this once
from your laptop with admin-ish AWS credentials:

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit values
terraform init                                  # uses LOCAL state (intentional)
terraform apply
```

Note the two outputs — `state_bucket_name` and `lock_table_name`. You'll plug
them into GitHub variables next.

### Step 2 — Let GitHub authenticate to AWS via OIDC

Create an IAM OIDC provider for `token.actions.githubusercontent.com` and an
IAM role that trusts it, scoped to *your* repo. Minimal trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:*" }
    }
  }]
}
```

Attach a permissions policy to this role allowing the EKS/VPC/IAM/S3/DynamoDB
actions Terraform needs. Tighten it over time toward least privilege.

> **Security note:** The `:sub` condition restricts which repo (and optionally
> which branch or environment) may assume the role. Keep it as narrow as you can.

### Step 3 — Configure GitHub repository variables

In **Settings → Secrets and variables → Actions → Variables**, add these
*repository variables* (they are not secret):

| Variable          | Example value                                  |
|-------------------|------------------------------------------------|
| `AWS_ROLE_ARN`    | `arn:aws:iam::123456789012:role/gha-eks`       |
| `AWS_REGION`      | `us-east-1`                                     |
| `TF_STATE_BUCKET` | `eks-platform-tfstate-123456789012`            |
| `TF_LOCK_TABLE`   | `eks-platform-tflock`                           |
| `PROJECT_NAME`    | `eks-platform`                                  |
| `ENVIRONMENT`     | `dev`                                           |

### Step 4 — (Recommended) Protect the production environment

Create a GitHub **Environment** named `production` and add **required
reviewers**. The cluster workflow ties applies on `main` to this environment,
so an apply will *pause for human approval*.

### Step 5 — Open a PR

Push this code to a branch and open a PR. The pipeline runs `plan` and comments
the diff. Merge to `main` to apply. Then run the printed `aws eks
update-kubeconfig …` command to get `kubectl` access.

---

## 7. The Terraform files, explained

Every `.tf` file in this repo is **heavily commented inline**, line by line.
Below is the higher-level tour; open each file to read the per-line notes.

### `terraform/bootstrap/` — the state backend

- **`main.tf`** — Declares the **S3 bucket** for state with three protections:
  *versioning* (roll back a bad state), *encryption* (state holds secrets), and
  a *public-access block* (state is never public). `prevent_destroy = true`
  stops an accidental `destroy` from wiping the bucket that holds all your
  state. It also creates the **DynamoDB lock table** with the mandatory
  `LockID` hash key, billed per-request so it costs almost nothing.
- **`variables.tf`** — Inputs (`aws_region`, `project_name`, `aws_account_id`)
  with `validation` blocks that reject bad input (e.g. a non-12-digit account
  ID) before any API call.
- **`outputs.tf`** — Prints the bucket and table names to paste into GitHub.

> This directory uses **local state** on purpose: it's the classic bootstrap
> chicken-and-egg — you can't store the backend's state in a backend that
> doesn't exist yet. It rarely changes after the first apply.

### `terraform/cluster/` — the EKS cluster

- **`backend.tf`** — Configures the **S3 backend** so this directory's state
  lives at key `cluster/terraform.tfstate`. Backend blocks can't take
  variables, so the bucket/table/region are passed at `init` time by the
  pipeline via `-backend-config` flags. Also pins the required Terraform
  version and the `aws`, `kubernetes`, and `tls` providers.
- **`providers.tf`** — Configures the **`aws`** provider (region + default
  tags applied to every resource) and the **`kubernetes`** provider. The
  Kubernetes provider authenticates with a **short-lived token** generated by
  `aws eks get-token` via an `exec` block — no kubeconfig is written to disk.
- **`variables.tf`** — Every tunable knob: region, Kubernetes version, VPC
  CIDR, AZ count, the baseline node group's size/instance types, admin role
  ARNs, and public-endpoint settings. Several have `validation` blocks.
- **`vpc.tf`** — Uses the official **VPC module** to build subnets across AZs.
  `cidrsubnet()` deterministically carves the VPC CIDR into per-AZ private and
  public ranges. Critically, it applies the **EKS discovery tags**
  (`kubernetes.io/role/elb`, `internal-elb`, and
  `kubernetes.io/cluster/<name>`) that EKS and the AWS Load Balancer Controller
  require to place load balancers correctly. NAT is single-gateway in dev
  (cheaper) and one-per-AZ in prod (highly available).
- **`eks.tf`** — The heart of the repo, via the official **EKS module**:
  - Creates the **control plane** at `kubernetes_version`, with private API
    access always on and public access configurable and CIDR-restricted.
  - Enables **IRSA** (the OIDC provider) for least-privilege workloads.
  - Installs the four core **add-ons**; `vpc-cni` is set `before_compute` so
    pod networking is ready the moment nodes join, and the EBS CSI driver is
    wired to a dedicated **IRSA role** (defined in the same file via the IAM
    helper module) rather than node permissions.
  - Defines the single **`system` managed node group**, **labeled**
    `role=system` and **tainted** `CriticalAddonsOnly=true:NoSchedule` so only
    core components run there and tenant workloads stay off it.
  - Uses **access entries** (`enable_cluster_creator_admin_permissions` plus
    any roles you pass) to grant cluster-admin — the modern replacement for the
    `aws-auth` ConfigMap.
- **`outputs.tf`** — The **contract** for downstream directories: cluster
  name/endpoint/CA, the node security group ID, the **OIDC provider ARN**, the
  VPC ID, and the private subnet IDs. Your future `node-groups` and `tenants`
  directories read these via `terraform_remote_state` so they never hardcode
  IDs. Also prints a ready-to-run `update-kubeconfig` command.

---

## 8. The GitHub Actions pipeline, explained

### `.github/workflows/cluster.yml`

This is the plan/apply pipeline for the cluster. Reading it top to bottom:

- **`on:`** — Triggers. It runs on **PRs** that touch `terraform/cluster/**`
  (plan only) and on **pushes to `main`** that touch the same paths (apply).
  `workflow_dispatch` adds a manual "Run" button. The `paths:` filter means
  unrelated commits don't needlessly run Terraform.
- **`permissions:`** — Grants the job token exactly what it needs:
  `id-token: write` (mandatory for OIDC), `contents: read` (checkout), and
  `pull-requests: write` (to post the plan comment).
- **`concurrency:`** — Serializes runs on the same ref and is set to **not**
  cancel an in-progress apply, so a deploy is never interrupted mid-flight.
- **`env:`** — Pulls non-secret config (Terraform version, region, state
  bucket/table) from repository variables so the YAML has no hardcoded
  account details.
- **`environment:`** — On `main`, binds the job to the `production` GitHub
  Environment, enabling the required-reviewer approval gate. PRs skip it.
- **Steps**, in order:
  1. **Checkout** the repo.
  2. **Configure AWS credentials (OIDC)** — exchanges the GitHub OIDC token for
     temporary AWS creds by assuming `AWS_ROLE_ARN`. No stored keys.
  3. **Setup Terraform** at the pinned version.
  4. **Format check** (`terraform fmt -check`) — fails if code isn't
     canonically formatted.
  5. **Init** — initializes the S3 backend, passing bucket/table/key/region as
     `-backend-config` flags.
  6. **Validate** — checks the configuration is internally consistent.
  7. **Plan** — writes a binary `tfplan` and a text `plan.txt`. Uses
     `-detailed-exitcode` semantics so "changes present" doesn't fail the step.
  8. **Comment Plan on PR** — posts `plan.txt` as a PR comment (truncating very
     long plans) so reviewers see the diff inline.
  9. **Fail if plan errored** — turns a real plan error (exit 1) into a failed
     run, while a benign "has changes" (exit 2) passes.
  10. **Apply** — only on `main` (never on a PR), applies the **exact** saved
      `tfplan`, guaranteeing what was reviewed is what ships.

### `.github/workflows/lint.yml`

Runs on every PR touching `terraform/**`:

- **TFLint** — catches provider-specific mistakes (deprecated instance types,
  invalid references) and enforces style. Configured by `.tflint.hcl`.
- **Trivy** (config scan) — scans the IaC for security misconfigurations at
  `HIGH`/`CRITICAL` severity and fails the PR on findings. While you triage
  initial findings, you can set its `exit-code` to `0` to make it advisory.

Together these are your **guardrails before the plan/apply pipeline even runs**.

---

## 9. Day-to-day: how to make changes

The golden rule: **never run `terraform apply` from your laptop against shared
state.** Let the pipeline do it. The workflow is:

1. **Branch.** `git checkout -b change/raise-system-node-max`.
2. **Edit** the relevant `.tf` file (e.g. bump `system_node_max_size`). Run
   `terraform fmt -recursive` locally to keep formatting clean.
3. **Open a PR.** The pipeline runs `fmt`, `init`, `validate`, and `plan`, then
   comments the plan. The lint/security workflow runs too.
4. **Review the plan.** Confirm the diff is *only* what you intended.
   Terraform plans show `+ create`, `~ update in-place`, `-/+ replace`, and
   `- destroy`. **Watch for `-/+ replace` and `destroy`** on stateful or
   critical resources — those can mean downtime or data loss.
5. **Merge to `main`.** The apply job runs and (if you configured it) **waits
   for approval** in the `production` environment before applying the exact
   reviewed plan.
6. **Verify.** Check the Actions log and, if needed, `kubectl get nodes`.

**Handling drift** (someone changed things in the console): the next `plan`
will show the difference. Either revert the manual change or codify it in
Terraform, then apply so state and reality match again.

**Upgrading Kubernetes:** bump `kubernetes_version` by **one minor version at a
time** (e.g. `1.30` → `1.31`), PR it, review, merge. EKS upgrades the control
plane, then the managed node group rolls to matching nodes.

**Rolling back:** revert the offending commit and merge; the pipeline applies
the previous desired state. (Note that some changes, like data deletion, can't
be undone by reverting code — always scrutinize `destroy`/`replace` in plans.)

---

## 10. Extending the platform: node groups & tenants

The repo is designed so these are **additive** and **isolated**. You do **not**
modify the `cluster` directory to add capacity or tenants.

### Adding more node groups (`terraform/node-groups/`)

1. Give the directory its **own backend** with key
   `node-groups/terraform.tfstate`.
2. Read the cluster's outputs via **`terraform_remote_state`**:

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

3. Define node groups as **data, not duplicated code** — a map you loop over:

   ```hcl
   locals {
     node_groups = {
       general = { instance_types = ["m5.large"],  min = 2, max = 6,  labels = { workload = "general" } }
       memory  = { instance_types = ["r5.xlarge"], min = 0, max = 4,  labels = { workload = "memory"  } }
       gpu     = { instance_types = ["g4dn.xlarge"], min = 0, max = 2, labels = { workload = "gpu" }, taints = { nvidia = { key = "nvidia.com/gpu", value = "true", effect = "NO_SCHEDULE" } } }
     }
   }
   ```

   Adding a pool is then **a few lines in this map** — no copy-pasted resource
   blocks. Attach each group to the cluster using
   `data.terraform_remote_state.cluster.outputs.cluster_name`,
   `…private_subnet_ids`, and `…node_security_group_id`.
4. Add a `node-groups.yml` workflow (copy `cluster.yml`, change `WORKING_DIR`
   to `terraform/node-groups` and the state `key`) so it has its own
   plan/apply pipeline.

### Adding multi-tenant projects (`terraform/tenants/`)

Build a reusable **tenant module** (`terraform/modules/tenant/`) that creates,
per tenant:

- a **Namespace**,
- a **ResourceQuota** and **LimitRange** (fair-share CPU/memory/object caps),
- a default-deny **NetworkPolicy** (tenants can't reach each other's pods),
- **RBAC** Role/RoleBinding scoping the tenant's users to their namespace,
- optionally a **dedicated node group** plus `nodeSelector`/tolerations for
  hard isolation,
- an **IRSA role** scoped to that tenant, trusting
  `data.terraform_remote_state.cluster.outputs.oidc_provider_arn`.

Then **onboarding a tenant is one module block**:

```hcl
module "tenant_acme" {
  source            = "../modules/tenant"
  tenant_name       = "acme"
  cpu_quota         = "20"
  memory_quota      = "40Gi"
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
}

module "tenant_globex" {
  source            = "../modules/tenant"
  tenant_name       = "globex"
  cpu_quota         = "10"
  memory_quota      = "20Gi"
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.oidc_provider_arn
}
```

For the strongest isolation, give **each tenant its own state key**
(`tenants/acme/terraform.tfstate`) so a mistake on one tenant can't affect
another's state. See `terraform/tenants/README.md` and
`terraform/node-groups/README.md` for the placeholders these will fill.

---

## 11. Troubleshooting

- **`Error acquiring the state lock`** — a previous run crashed holding the
  DynamoDB lock. Confirm no run is active, then
  `terraform force-unlock <LOCK_ID>` (use with care).
- **OIDC `Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the IAM
  role trust policy's `:sub` condition doesn't match your repo/branch, or the
  OIDC provider/thumbprint is misconfigured.
- **`fmt -check` fails the build** — run `terraform fmt -recursive` and commit.
- **Nodes stuck `NotReady` / pods pending** — usually the `vpc-cni` add-on or
  subnet tags; confirm the EKS discovery tags exist on subnets and the CNI
  add-on is healthy.
- **`kubectl` "You must be logged in to the server (Unauthorized)"** — your IAM
  principal lacks an access entry. Add its ARN to `cluster_admin_role_arns`,
  PR, and apply, or run the printed `update-kubeconfig` with the right profile.

---

### A note on cost

An EKS control plane bills hourly, and worker nodes, NAT gateways, and EBS
volumes all cost money. In `dev` this repo uses a single NAT gateway and small
`t3.medium` nodes to keep costs modest. **Run `terraform destroy` (or tear down
via a dedicated workflow) when you're done experimenting** — but remember the
bootstrap bucket is `prevent_destroy` on purpose.
