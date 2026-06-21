# Troubleshooting Journal — EKS Pipeline Bring-Up

This document records every problem we hit getting the GitHub Actions → Terraform
→ EKS pipeline working, in the order they happened, with **what** broke, **why**
it broke, and **how** we fixed it. Read it top to bottom and you'll understand
the whole debugging arc; jump to a heading if you hit the same error.

A useful mental model for the whole journey: the pipeline fails **one layer at a
time**, and each layer only reveals its problem once the layer before it works.
First the workflow has to trigger, then it has to read its config, then log in to
AWS, then reach the state backend, then have permission to build resources. Most
of what follows is peeling those layers in order.

---

## Quick index

1. [Node 20 deprecation warning](#1-node-20-deprecation-warning-not-an-error)
2. [Missing `aws-region` input](#2-missing-aws-region-input)
3. [All repository variables empty](#3-all-repository-variables-came-back-empty)
4. [OIDC: "Request ARN is invalid"](#4-oidc-request-arn-is-invalid)
5. [OIDC: "Source Account ID is needed"](#5-oidc-source-account-id-is-needed)
6. [Pipeline not triggering](#6-pipeline-not-triggering)
7. [`terraform fmt` check failed](#7-terraform-fmt-check-failed-exit-code-3)
8. [S3 state: 403 Forbidden](#8-s3-state-403-forbidden)
9. [DynamoDB lock: AccessDenied](#9-dynamodb-lock-accessdenied)
10. [Mid-apply: Logs + IAM tagging denied](#10-mid-apply-cloudwatch-logs--iam-tagging-denied)
11. [The root pattern + permanent fix](#11-the-root-pattern--the-permanent-fix)

---

## 1. Node 20 deprecation warning (not an error)

**What we saw**
```
Node 20 is being deprecated. This workflow is running with Node 24 by default...
```

**Why it happened**
GitHub moved its Actions runners from Node 20 to Node 24. This is a **warning**,
not a failure — it never stopped the run.

**What we did**
Nothing. The actions we use are pinned to major versions (`@v4`, `@v3`), so they
pick up Node 24 automatically as their maintainers update them. We specifically
did **not** set `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION` — the name says it all,
and forcing the old runtime is the wrong direction.

**Lesson:** separate warnings from errors. Only the line that says `Error:` and
the non-zero exit code actually stop a run.

---

## 2. Missing `aws-region` input

**What we saw**
```
Run aws-actions/configure-aws-credentials@v4
Error: Input required and not supplied: aws-region
```

**Why it happened**
The credentials step reads its region from `${{ vars.AWS_REGION }}`. That came
through **empty**, and an empty string passed silently into the action, which
then refused to continue. `vars.*` only reads repository/environment **Variables**
— not Secrets — so a missing or misplaced variable yields an empty value with no
warning.

**What we did**
Two changes to `cluster.yml`:
- Added a **fallback default** so an empty variable can't crash the step:
  ```yaml
  AWS_REGION: ${{ vars.AWS_REGION || 'us-east-1' }}
  ```
- Added a **preflight step** that checks all six required variables up front and
  fails with a clear message naming whichever is missing — so we'd never again
  waste a run on a cryptic downstream error.

**Lesson:** validate configuration at the *start* of a pipeline with readable
errors, rather than letting an empty value surface as a confusing failure ten
steps later.

---

## 3. All repository variables came back empty

**What we saw**
The new preflight step fired and reported **every** variable missing:
```
Error: Repository variable 'AWS_ROLE_ARN' is not set (or is empty).
Error: Repository variable 'AWS_REGION' is not set (or is empty).
... (all six)
```

**Why it happened**
When *all* of them are empty, it's almost never six separate mistakes — it's one
systemic cause. The usual culprits:
1. They were added under the **Secrets** tab, but the workflow reads `vars.*`
   (the **Variables** tab). `vars.*` cannot see Secrets.
2. They were added to a GitHub **Environment**, but the job that needed them
   didn't load that environment. (Our job only attaches the `production`
   environment on `main` — on a PR it loads none, so environment-scoped
   variables are invisible.)
3. The PR came from a **fork**, and GitHub withholds variables from fork PRs for
   security.

**What we did**
- Created the six values as **repository Variables** (Settings → Secrets and
  variables → Actions → **Variables** tab), with exact, case-sensitive names:
  `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`, `TF_LOCK_TABLE`,
  `PROJECT_NAME`, `ENVIRONMENT`.
- Upgraded the preflight to **print diagnostics** (event name, ref, whether an
  environment loaded, whether it's a fork PR) so the next failure would point at
  the exact cause.

**Lesson:** *Variables* ≠ *Secrets*, and *repository* scope ≠ *environment*
scope. For non-secret config that PRs also need, use repository Variables.

---

## 4. OIDC: "Request ARN is invalid"

**What we saw**
```
Error: Could not assume role with OIDC: Request ARN is invalid
```

**Why it happened**
Progress! The variables were now set, GitHub built its token, and it tried to
assume the role — but the value in `AWS_ROLE_ARN` wasn't a correctly-formed ARN.
A role ARN must look exactly like:
```
arn:aws:iam::123456789012:role/github-actions-eks
```
"Invalid" means the text didn't match that shape — typically the role *name* was
pasted instead of the full ARN, the `arn:aws:iam::` prefix was missing, the
account number was wrong, or a stray space/quote broke it.

**What we did**
- Created the OIDC **identity provider** in IAM (provider URL
  `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`).
- Created the **role** with a trust policy scoped to our repo via the
  `token.actions.githubusercontent.com:sub` condition
  (`repo:ORG/REPO:*`).
- Copied the **exact ARN** from the role's page into the `AWS_ROLE_ARN` variable
  — the whole string starting with `arn:`.

We also avoided naming the role `GitHubActions`, which is known to fail.

**Lesson:** an ARN is a full address, not a name. Copy it from AWS rather than
typing it.

---

## 5. OIDC: "Source Account ID is needed"

**What we saw**
```
Error: Source Account ID is needed if the Role Name is provided and not the Role Arn.
```

**Why it happened**
A close cousin of #4. The `configure-aws-credentials` action accepts either a
full ARN *or* a bare role name plus a separate account ID. It looked at our
`role-to-assume` value, decided it was a **name** (because it didn't start with
`arn:aws:iam::`), and then complained that a name alone isn't enough. So the
variable still didn't contain a complete ARN — a frequent cause is accidentally
setting it to `$ROLE_NAME` (`github-actions-eks`) instead of `$ROLE_ARN`
(`arn:aws:iam::...:role/github-actions-eks`); the two are one character apart in
the variable name but completely different values.

**What we did**
Put the **complete ARN** into `AWS_ROLE_ARN`, confirmed it with
`aws iam get-role --role-name ... --query Role.Arn`, and verified what GitHub
actually stored.

**Lesson:** when the action says "name not ARN," the fix is always to supply the
full ARN — same root cause as #4, different phrasing.

---

## 6. Pipeline not triggering

**What we saw**
A push happened, but no workflow ran.

**Why it happened**
Our `cluster.yml` only triggers on changes under specific **paths**:
```yaml
paths:
  - "terraform/cluster/**"
  - ".github/workflows/cluster.yml"
```
So commits **outside** those paths (READMEs, the OIDC/CloudFormation files,
anything in `terraform/bootstrap/`) correctly run nothing. Other possibilities we
ruled out: pushing to a branch without opening a PR (the workflow runs on PRs or
on pushes to `main`), the workflow file not existing on the pushed branch, a YAML
error, or Actions being disabled.

**What we did**
Confirmed which branch and which files changed, and used the manual trigger
(`workflow_dispatch`, via the Actions "Run workflow" button or
`gh workflow run cluster.yml`) to run it regardless. For a real change, we edited
a file **inside** `terraform/cluster/` so the path filter matched.

**Lesson:** path filters are a feature, not a bug. If "nothing ran," first check
whether your change touched a watched path on a watched event.

---

## 7. `terraform fmt` check failed (exit code 3)

**What we saw**
```
terraform fmt -check -recursive
vpc.tf
Error: Terraform exited with code 3.
```

**Why it happened**
`terraform fmt -check` only *verifies* canonical formatting; exit code 3 means a
file isn't formatted. It named `vpc.tf`. The cause was misaligned `=` signs: in a
contiguous block of arguments, Terraform aligns all `=` to the longest key, and
`one_nat_gateway_per_az` is longer than its neighbors, so the column was off.
Nothing was logically broken — purely whitespace.

**What we did**
Aligned the three NAT-gateway arguments' `=` signs. The general fix is one
command run locally:
```bash
terraform fmt -recursive
```
which rewrites every file to canonical form.

**Lesson:** keep `terraform fmt` in your local workflow (or a pre-commit hook) so
formatting never reaches CI. A failing format check is trivial to fix but easy to
prevent.

---

## 8. S3 state: 403 Forbidden

**What we saw**
```
Error refreshing state: Unable to access object "cluster/terraform.tfstate"
in S3 bucket "eks-platform-tfstate-zac2026": ... StatusCode: 403 ...
api error Forbidden
```

**Why it happened**
Big milestone — login now worked, and Terraform tried to read its state file. A
**403 (Forbidden)**, not 404, means "you're not allowed," not "it's missing." The
pipeline role's permissions policy lacked S3 access to that bucket — almost
certainly because the policy was written against a placeholder bucket name rather
than the real `eks-platform-tfstate-zac2026`, so the grant never matched.

A subtlety we addressed: S3 permissions come in **two scopes** — `ListBucket`
acts on the **bucket** ARN (no `/*`), while `GetObject`/`PutObject`/`DeleteObject`
act on the **object** ARN (`/*`). Both are required; granting only the `/*` form
is a common cause of exactly this 403.

**What we did**
Attached an S3 policy to the role with both scopes, scoped to the real bucket. We
also noted that if the bucket uses a customer-managed **KMS** key, missing KMS
permissions can *also* surface as an S3 403 — so KMS access may be needed too.

**Lesson:** 403 = permissions, 404 = existence. And remember S3's bucket-vs-object
two-scope rule.

---

## 9. DynamoDB lock: AccessDenied

**What we saw**
```
Error acquiring the state lock
... AccessDeniedException: User: .../github-actions-eks/gha-eks-cluster is not
authorized to perform: dynamodb:PutItem on resource: .../table/eks-platform-tflock
because no identity-based policy allows the dynamodb:PutItem action
```

**Why it happened**
Before writing state, Terraform writes a **lock record** to DynamoDB so two runs
can't collide. The role could authenticate but lacked `dynamodb:PutItem` on the
lock table. The follow-on `ResourceNotFoundException` on `GetItem` was a
red herring — a side effect of the same permission failure, not a missing table.
(We confirmed the table itself existed; the AccessDenied wording, which names the
table, was the giveaway.) The `tfplan: no such file` errors were also downstream:
the plan never ran because the lock failed first.

**What we did**
Attached a DynamoDB policy granting `GetItem`, `PutItem`, `DeleteItem` (the three
actions Terraform's S3 backend needs) on the lock table, scoped to its ARN. We
also checked that both backend policies — S3 *and* DynamoDB — were attached, so
the next run would clear the entire backend in one go.

**Lesson:** the S3 backend needs **both** S3 *and* DynamoDB permissions, and they
fail one at a time. Grant both together. Also: a stuck lock from a crashed run is
cleared with `terraform force-unlock <LOCK_ID>` — but only if the error shows a
lock ID, not an AccessDenied.

---

## 10. Mid-apply: CloudWatch Logs + IAM tagging denied

**What we saw**
The apply was now genuinely building infrastructure (NAT gateway, routes, subnets
created) before failing on:
```
AccessDeniedException: ... not authorized to perform: logs:CreateLogGroup ...
AccessDenied: ... not authorized to perform: iam:TagPolicy ... (×3)
```

**Why it happened**
Two more gaps, each named precisely:
- The EKS module creates a **CloudWatch log group** for control-plane logs — the
  role couldn't create log groups.
- The IAM errors were **`iam:TagPolicy`**, not `CreatePolicy` — the role could
  *create* policies but not *tag* them, and the module tags every policy it
  creates, so each one failed at the tagging step.

**What we did**
Added the missing CloudWatch Logs actions (`logs:CreateLogGroup` and friends) and
the IAM tagging actions (`iam:TagPolicy`, `iam:TagRole`, etc.) to the role's
permissions.

**Lesson:** "create" and "tag" are **separate** IAM actions. A policy that grants
creation but not tagging will fail the moment a tool tags what it created — and
Terraform modules tag almost everything.

---

## 11. The root pattern + the permanent fix

Step back and the through-line is obvious. Errors **2–6** were the pipeline
learning to *start and log in* (config, variables, OIDC). Errors **8–10** were
all the **same kind of problem**: the pipeline role's permissions policy was
*incomplete*, and each missing action only revealed itself when Terraform reached
the resource that needed it. Invalid ARN → S3 403 → DynamoDB AccessDenied → Logs
denied → IAM-tag denied: different services, identical root cause.

**Why it kept happening:** a hand-built least-privilege policy is permissioned
*reactively*. The EKS + VPC + IRSA modules create a large number of resources
across many services (EKS, EC2/VPC, AutoScaling, ELB, IAM, CloudWatch Logs, KMS,
S3, DynamoDB), and you can't easily know every action up front — so you discover
them one failure at a time.

**The permanent fix** was to assemble a **complete** permissions policy covering
all of those services at once, instead of bolting on actions reactively. We did
this two ways:

- **`attach-eks-permissions.sh`** — attaches the full policy set to the existing
  role in one shot (fastest unblock for an in-progress apply).
- **`terraform/bootstrap/github-oidc-role.yaml`** — a CloudFormation template
  that creates the role (and optionally the OIDC provider) with the same complete
  policy set, fully version-controlled. See
  `terraform/bootstrap/README-oidc-role.md` for deploy steps.

Both include the specific actions that bit us — `iam:TagPolicy`, `iam:TagRole`,
`logs:CreateLogGroup`, the full KMS set, and the two-scope S3 plus DynamoDB
backend access.

### Order of operations that actually works

Doing it in this order avoids the whack-a-mole entirely:

1. **Bootstrap** the state backend (S3 bucket + DynamoDB lock table) — once.
2. **Create the pipeline role** with the *complete* permissions policy (via the
   CloudFormation template), and the OIDC provider if it doesn't exist.
3. **Set the six repository Variables**, with `AWS_ROLE_ARN` = the exact ARN the
   stack outputs.
4. **Open a PR** that touches `terraform/cluster/**` so the pipeline triggers.
5. **Run `terraform fmt -recursive`** before pushing so the format check passes.
6. Watch **plan** on the PR, then **apply** on merge.

### Cleanup reminders

- A crashed run can leave a **stale lock**: `terraform force-unlock <LOCK_ID>`
  (only when the error shows a lock ID).
- A partial apply leaves **real resources** (e.g. a NAT gateway) that **bill
  hourly**. They're tracked in state and the next apply resumes from them — but
  if you're pausing to debug, be aware of the cost, and tear down with a destroy
  when you're done experimenting.

### Hardening (after it works)

The complete policy uses broad actions for the create-everything services
because resource names aren't known ahead of time (S3 and DynamoDB stay scoped to
your named bucket/table). For production, add a **permissions boundary** to cap
what any role the pipeline creates can do, and use **IAM Access Analyzer** to
generate a trimmed policy from real usage after the first successful apply.

---

## One-line summary of each fix

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Node 20 warning | Runner moved to Node 24 | Ignore (warning, not error) |
| 2 | `aws-region` not supplied | Empty `vars.AWS_REGION` | Set variable + fallback + preflight |
| 3 | All variables empty | Added as Secrets / to an Environment | Use repository **Variables** |
| 4 | Request ARN invalid | Name pasted, not full ARN | Paste complete `arn:aws:iam::...` |
| 5 | Source Account ID needed | Value wasn't an ARN | Same — full ARN |
| 6 | Pipeline didn't run | Change outside watched paths | Edit under `terraform/cluster/**` or dispatch |
| 7 | `fmt` exit code 3 | Misaligned `=` in vpc.tf | `terraform fmt -recursive` |
| 8 | S3 403 | Role lacked S3 (bucket name mismatch) | Grant S3, both bucket + object scopes |
| 9 | DynamoDB AccessDenied | Role lacked lock-table actions | Grant Get/Put/DeleteItem |
| 10 | Logs + IAM-tag denied | Missing logs + `iam:Tag*` actions | Add those actions |
| 11 | Recurring AccessDenied | Reactive, incomplete policy | Apply the **complete** policy (script/CFN) |
