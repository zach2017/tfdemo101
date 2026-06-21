Good news: this error means progress. Your variables are now set (the preflight passed), GitHub built its login token, and it tried to assume the AWS role. The only thing wrong now is the **`AWS_ROLE_ARN` value itself** — AWS is saying "the role name you handed me isn't a valid ARN."

Let me explain what's happening in plain terms, then walk you through the fix step by step.

## What "Request ARN is invalid" actually means

An **ARN** (Amazon Resource Name) is just AWS's full address for a thing. A role ARN has to look *exactly* like this:

```
arn:aws:iam::123456789012:role/my-role-name
```

Breaking that down piece by piece:

- `arn:aws:iam::` — fixed text, always the same for IAM roles
- `123456789012` — your 12-digit AWS account number
- `:role/` — fixed text
- `my-role-name` — the name of your role

"Request ARN is invalid" means the text in your `AWS_ROLE_ARN` variable doesn't match that shape. The usual culprits are: you put just the role *name* (`gha-eks`) instead of the full ARN, there's a typo or extra space, the account number isn't 12 digits, or a curly quote/line break sneaked in when you pasted it.

## Step-by-step fix

### Step 1 — Find your real account number

You need your 12-digit AWS account ID. Two easy ways:

- **In the AWS Console:** click your account name in the top-right corner — the number shows in the dropdown.
- **From a terminal** (if your AWS CLI is set up): run `aws sts get-caller-identity`. The `Account` field is your 12 digits.

Write it down.

### Step 2 — Check the role actually exists, and get its exact ARN

This is the important part — don't build the ARN from memory, **copy it from AWS** so it's exact.

1. Go to the AWS Console → search for and open **IAM**.
2. In the left menu, click **Roles**.
3. Look for the role you made for GitHub (you may have named it something like `gha-eks` or `github-actions-eks`).
4. **If you see it:** click it. At the top of the role's page is its **ARN** with a copy icon. Click copy. That's the exact value you need.
5. **If you do NOT see it:** the role was never created. That's a real possibility and would also cause this error. Skip to the "If the role doesn't exist yet" section below.

### Step 3 — Paste the exact ARN into the GitHub variable

1. In your GitHub repo: **Settings → Secrets and variables → Actions → the "Variables" tab**.
2. Find **`AWS_ROLE_ARN`** and click the edit (pencil) icon.
3. Delete whatever's there and paste the ARN you just copied. It must be the **whole thing** starting with `arn:aws:iam::`, not just the role name.
4. Make sure there are **no spaces** before or after it, and no line break. Save.

### Step 4 — Re-run the workflow

Push a commit, or in the **Actions** tab open the failed run and click **Re-run jobs**. This time the "Configure AWS credentials" step should pass and you'll see your account/role printed by the "Verify AWS identity" step.

## A common subtle trap

Even with a *perfectly formatted* ARN, you can still get "Could not assume role with OIDC" if the **trust policy** on the role doesn't allow your specific repo. The error wording differs slightly (it'd usually say "Not authorized to perform sts:AssumeRoleWithWebIdentity"), but it's worth knowing both halves have to be right:

1. **The ARN must be valid** ← this is your current error
2. **The role must trust your repo** ← the next thing to verify

The trust relationship is what says "GitHub Actions, running from *this specific repository*, is allowed to borrow this role." If that's wrong or missing, AWS refuses even when the ARN is perfect.

---

Before I write out the full role-creation steps (in case Step 2 showed the role doesn't exist), let me make sure I point you at the **current** official AWS and GitHub instructions, since the exact console screens and the recommended trust-policy settings have changed over time.My grounding is current and matches what I expected. One useful detail confirmed from the official sources: there's a known quirk that **naming your role `GitHubActions` (or `GitHubAction`) can fail** — AWS reserves those names — so pick a different name. Here's the complete walkthrough, written simply.

## Quick check first (do this before creating anything)

Your error is specifically "**Request ARN is invalid**" — that's a *formatting* problem with the ARN text, distinct from "Not authorized" (which would mean the role exists but doesn't trust your repo). So before building a new role, open AWS IAM → Roles and see if your GitHub role is already there:

- **If the role IS there** → you probably just have a malformed value in the `AWS_ROLE_ARN` variable. Copy the exact ARN from the role's page, paste it into the GitHub variable (the four-step fix from my previous message), re-run. Done.
- **If the role is NOT there** → follow the full setup below.

## Full OIDC setup, step by step

There are two things to build in AWS: a **trust anchor** (telling AWS to trust GitHub at all) and a **role** (the specific identity your pipeline borrows, locked to your repo).

### Part A — Create the OIDC identity provider (the trust anchor)

This is a one-time thing per AWS account. It tells AWS "tokens from GitHub are real; here's how to verify them."

1. In the AWS Console, open **IAM**.
2. Left menu → **Identity providers**.
3. Click **Add provider**.
4. Choose **OpenID Connect**.
5. For **Provider URL**, type exactly (all lowercase):
   ```
   https://token.actions.githubusercontent.com
   ```
6. Click **Get thumbprint** (AWS fills it in for you — you don't have to know the value).
7. For **Audience**, type exactly:
   ```
   sts.amazonaws.com
   ```
8. Click **Add provider**.

That's the trust anchor built. The first step in this process is to create an OIDC provider which you will use in the trust policy for the IAM role used in this action. Open the IAM console. In the left navigation menu, choose Identity providers. In the Identity providers pane, choose Add provider. For Provider type, choose OpenID Connect.

### Part B — Create the role and lock it to your repo

Now the role your pipeline assumes.

1. Still in IAM → left menu → **Roles** → **Create role**.
2. For **Trusted entity type**, choose **Web identity** (not the default "AWS service").
3. For **Identity provider**, pick the `token.actions.githubusercontent.com` one you just created.
4. For **Audience**, pick `sts.amazonaws.com`.
5. There may be optional fields for **GitHub organization / repository / branch** — fill in your org and repo here if offered. This is what locks the role to *only* your repository.
6. Click **Next**, attach a permissions policy (more on this just below), click **Next**.
7. **Name the role** — anything *except* `GitHubActions` (that name is known to fail). Use something like `github-actions-eks` or `gha-eks-cluster`.
8. Click **Create role**.
9. Open the role you just made and **copy its ARN** from the top of the page. That exact string is what goes into the GitHub `AWS_ROLE_ARN` variable.

### Part C — Confirm the trust policy is locked to your repo

After creating the role, open it → the **Trust relationships** tab → **Edit trust policy**. It should look like this (substitute your real account number, org, and repo):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/YOUR-REPO:*"
      }
    }
  }]
}
```

What that last condition line does: AWS Identity and Access Management (IAM) recommends that users evaluate the IAM condition key, token.actions.githubusercontent.com:sub, in the trust policy of any role that trusts GitHub's OIDC identity provider (IdP). Evaluating this condition key in the role trust policy limits which GitHub actions are able to assume the role. The `:*` at the end means "any branch in this repo." If you want to restrict to only the `main` branch, replace it with `repo:YOUR-ORG/YOUR-REPO:ref:refs/heads/main`.

### Part D — Permissions on the role

The trust policy controls *who can borrow* the role; a separate **permissions policy** controls *what the role can do* once borrowed. For your EKS pipeline, the role needs to create EKS, VPC, IAM, and read/write the S3 state bucket and DynamoDB lock table. The IAM role can now authenticate, but it has no permissions yet. You need to attach a policy that defines what your workflow is actually allowed to do in AWS. Only grant the permissions your workflow genuinely needs. To get going you can attach broader managed policies and tighten later — just never attach AdministratorAccess to a CI/CD role as a permanent setup.

### Part E — Put the ARN in GitHub and re-run

1. GitHub repo → **Settings → Secrets and variables → Actions → Variables** tab.
2. Edit **`AWS_ROLE_ARN`**, paste the exact ARN from Part B step 9, no spaces/line breaks, save.
3. **Actions** tab → open the failed run → **Re-run jobs**.

The "Verify AWS identity" step I added earlier will print your account and the assumed role when this succeeds — that's your confirmation the whole OIDC chain works.

## If it still fails after this

The error message tells you which half is wrong:

- **"Request ARN is invalid"** (your current one) → the ARN *text* is still malformed. Re-copy it from the role page; check for a missing `arn:aws:iam::` prefix, wrong digit count, or a stray space.
- **"Not authorized to perform sts:AssumeRoleWithWebIdentity"** → the ARN is fine but the **trust policy doesn't match**. Re-check the `repo:YOUR-ORG/YOUR-REPO` spelling and casing in Part C, and confirm whether you locked it to a branch that the run isn't using.
- **Anything about missing `id-token`** → that's in the workflow, not AWS — but your workflow already has `id-token: write`, so you shouldn't hit it.

The two authoritative pages to keep open while you do this: the [GitHub Docs OIDC-in-AWS guide](https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) and the [AWS step-by-step blog](https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/).

Want me to add a small debug step to the pipeline that prints the OIDC token's `sub` claim (the exact `repo:org/repo:ref:...` string GitHub is sending)? That makes trust-policy mismatches obvious because you can compare it directly against what's in your policy — just note it should only be used in a private repo, since the claim values can be sensitive.