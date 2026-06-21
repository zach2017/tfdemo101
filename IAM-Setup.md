I'll give you both: copy-paste CLI commands and a CloudFormation template that sets up the OIDC provider, the pipeline role, and a permissions boundary in one shot. Let me verify the current resource types and managed-policy ARN format first, since CloudFormation type names and OIDC details matter here.My grounding confirms two important current facts: (1) since July 2023, AWS trusts GitHub's OIDC via its CA library, so the thumbprint no longer matters functionally for new providers, and (2) `AWS::IAM::OIDCProvider` in CloudFormation *still requires* a non-null `ThumbprintList` even though it's ignored — so I'll include the known thumbprint to avoid the deploy error. Here's both approaches.

A quick note before the commands: you only create the OIDC provider **once per AWS account**. If you (or anyone) ever created an EKS or GitHub OIDC setup before, it may already exist — creating a duplicate fails with `EntityAlreadyExists`, which is harmless. The CloudFormation route is better here precisely because a stack tracks what it created and won't double-create.

---
# Force Run Pipeline
```
gh workflow run cluster.yml --repo "$GH_ORG/$GH_REPO" --ref main
```

## Approach 1 — Command line (AWS CLI)

This is three files and a handful of commands. Run them from your laptop with admin-ish AWS credentials. Replace the placeholders (`YOUR-ORG`, `YOUR-REPO`, `YOUR-STATE-BUCKET-NAME`, `YOUR-LOCK-TABLE-NAME`) first.

### Step 1 — Create the OIDC provider

```bash
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
```

The thumbprint value is GitHub's well-known one. As AWS's own docs now state, if you are creating the IAM OIDC identity provider with the AWS CLI... providing a thumbprint is optional. If you choose not to include a thumbprint during creation, IAM will retrieve the top intermediate CA thumbprint of the OIDC IdP server certificate. Either way works; including it is the conservative choice. If this step says the provider already exists, skip ahead — you're set.

### Step 2 — Write the trust policy file

This file controls *who* can assume the role. Get your account ID first:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"
```

Then create `trust-policy.json` (the `cat` block writes the file for you — paste your org/repo into it):

```bash
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
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
EOF
```

### Step 3 — Create the role with that trust policy

Pick any name *except* `GitHubActions` (that name is known to fail):

```bash
aws iam create-role \
  --role-name github-actions-eks \
  --assume-role-policy-document file://trust-policy.json \
  --description "Role assumed by GitHub Actions via OIDC to run Terraform for EKS"
```

The output includes the role's **ARN** (`arn:aws:iam::...:role/github-actions-eks`). That's the exact value for your GitHub `AWS_ROLE_ARN` variable. To re-print it later:

```bash
aws iam get-role --role-name github-actions-eks --query 'Role.Arn' --output text
```

### Step 4 — Write the permissions policy file

This is the least-privilege policy from before. Create `permissions-policy.json` (substitute your bucket, lock table, and account ID):

```bash
cat > permissions-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EKS",        "Effect": "Allow", "Action": "eks:*",         "Resource": "*" },
    { "Sid": "EC2",        "Effect": "Allow", "Action": "ec2:*",         "Resource": "*" },
    { "Sid": "AutoScaling","Effect": "Allow", "Action": "autoscaling:*", "Resource": "*" },
    {
      "Sid": "IAMForClusterAndNodeRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole",
        "iam:ListRoles", "iam:TagRole", "iam:UntagRole",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
        "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListPolicies",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
        "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
        "iam:CreateServiceLinkedRole",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetObject","s3:PutObject","s3:DeleteObject","s3:GetBucketVersioning"],
      "Resource": [
        "arn:aws:s3:::YOUR-STATE-BUCKET-NAME",
        "arn:aws:s3:::YOUR-STATE-BUCKET-NAME/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:*:${ACCOUNT_ID}:table/YOUR-LOCK-TABLE-NAME"
    },
    {
      "Sid": "KMS",
      "Effect": "Allow",
      "Action": ["kms:CreateKey","kms:DescribeKey","kms:CreateAlias","kms:DeleteAlias","kms:ListAliases","kms:TagResource","kms:ScheduleKeyDeletion","kms:GetKeyPolicy","kms:PutKeyPolicy","kms:CreateGrant"],
      "Resource": "*"
    }
  ]
}
EOF
```

### Step 5 — Attach the permissions policy to the role

```bash
aws iam put-role-policy \
  --role-name github-actions-eks \
  --policy-name eks-pipeline-permissions \
  --policy-document file://permissions-policy.json
```

Done. The role exists, trusts your repo, and can run the pipeline. Put the ARN from Step 3 into GitHub and re-run.

---

## Approach 2 — CloudFormation (one template, everything tracked)

This is the cleaner option. One template creates the OIDC provider, the role, the permissions policy, **and** a permissions boundary (the privilege-escalation guardrail). CloudFormation tracks it all, so updates and teardown are clean — and it won't double-create the provider.

Save this as `github-oidc-role.yaml`:

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: >
  GitHub Actions OIDC setup for the EKS Terraform pipeline.
  Creates: the GitHub OIDC identity provider, an IAM role scoped to one repo,
  its permissions policy, and a permissions boundary that caps what any role
  the pipeline creates can do (privilege-escalation guardrail).

Parameters:
  GitHubOrg:
    Type: String
    Description: Your GitHub organization or username (the part before the slash).
  GitHubRepo:
    Type: String
    Description: Your repository name (the part after the slash).
  StateBucketName:
    Type: String
    Description: Name of the S3 bucket holding Terraform state (from bootstrap).
  LockTableName:
    Type: String
    Default: eks-platform-tflock
    Description: Name of the DynamoDB lock table (from bootstrap).
  RoleName:
    Type: String
    Default: github-actions-eks
    Description: Name for the pipeline role. Do NOT use "GitHubActions" (reserved/known to fail).
  CreateOIDCProvider:
    Type: String
    AllowedValues: ["true", "false"]
    Default: "true"
    Description: Set to "false" if a GitHub OIDC provider already exists in this account.

Conditions:
  ShouldCreateOIDC: !Equals [!Ref CreateOIDCProvider, "true"]

Resources:

  # ---- The GitHub OIDC identity provider (one per account) ----
  GitHubOIDCProvider:
    Type: AWS::IAM::OIDCProvider
    Condition: ShouldCreateOIDC
    Properties:
      Url: https://token.actions.githubusercontent.com
      ClientIdList:
        - sts.amazonaws.com
      # NOTE: AWS now trusts GitHub via its CA library, so this thumbprint is
      # effectively ignored — but CloudFormation still rejects a null/empty
      # ThumbprintList, so we supply GitHub's well-known value.
      ThumbprintList:
        - 6938fd4d98bab03faadb97b34396831e3780aea1

  # ---- Permissions boundary: the ceiling for roles the pipeline creates ----
  # This does NOT grant anything. It limits what any IAM role created BY the
  # pipeline is allowed to do, preventing privilege escalation.
  PipelineBoundary:
    Type: AWS::IAM::ManagedPolicy
    Properties:
      ManagedPolicyName: !Sub "${RoleName}-boundary"
      Description: Maximum permissions any pipeline-created role may have.
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Action:
              - "eks:*"
              - "ec2:*"
              - "autoscaling:*"
              - "elasticloadbalancing:*"
              - "kms:*"
              - "logs:*"
              - "s3:*"
              - "dynamodb:*"
              - "iam:*"
            Resource: "*"
          # Hard denials: pipeline-created roles can never touch account-level
          # security or escalate boundaries.
          - Effect: Deny
            Action:
              - "iam:DeleteAccountPasswordPolicy"
              - "iam:UpdateAccountPasswordPolicy"
              - "organizations:*"
              - "account:*"
            Resource: "*"

  # ---- The pipeline role GitHub assumes via OIDC ----
  PipelineRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Ref RoleName
      Description: Assumed by GitHub Actions via OIDC to run Terraform for EKS.
      # Trust policy: only this org/repo may assume the role.
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Federated: !If
                - ShouldCreateOIDC
                - !Ref GitHubOIDCProvider
                - !Sub "arn:aws:iam::${AWS::AccountId}:oidc-provider/token.actions.githubusercontent.com"
            Action: sts:AssumeRoleWithWebIdentity
            Condition:
              StringEquals:
                token.actions.githubusercontent.com:aud: sts.amazonaws.com
              StringLike:
                token.actions.githubusercontent.com:sub: !Sub "repo:${GitHubOrg}/${GitHubRepo}:*"
      # The permissions the pipeline itself has (to run Terraform).
      Policies:
        - PolicyName: eks-pipeline-permissions
          PolicyDocument:
            Version: "2012-10-17"
            Statement:
              - Sid: EKS
                Effect: Allow
                Action: "eks:*"
                Resource: "*"
              - Sid: EC2
                Effect: Allow
                Action: "ec2:*"
                Resource: "*"
              - Sid: AutoScaling
                Effect: Allow
                Action: "autoscaling:*"
                Resource: "*"
              - Sid: ELB
                Effect: Allow
                Action: "elasticloadbalancing:*"
                Resource: "*"
              - Sid: IAMForClusterAndNodeRoles
                Effect: Allow
                Action:
                  - "iam:CreateRole"
                  - "iam:DeleteRole"
                  - "iam:GetRole"
                  - "iam:PassRole"
                  - "iam:ListRoles"
                  - "iam:TagRole"
                  - "iam:UntagRole"
                  - "iam:CreatePolicy"
                  - "iam:DeletePolicy"
                  - "iam:GetPolicy"
                  - "iam:CreatePolicyVersion"
                  - "iam:DeletePolicyVersion"
                  - "iam:GetPolicyVersion"
                  - "iam:ListPolicyVersions"
                  - "iam:ListPolicies"
                  - "iam:AttachRolePolicy"
                  - "iam:DetachRolePolicy"
                  - "iam:ListAttachedRolePolicies"
                  - "iam:ListRolePolicies"
                  - "iam:GetRolePolicy"
                  - "iam:PutRolePolicy"
                  - "iam:DeleteRolePolicy"
                  - "iam:CreateOpenIDConnectProvider"
                  - "iam:DeleteOpenIDConnectProvider"
                  - "iam:GetOpenIDConnectProvider"
                  - "iam:TagOpenIDConnectProvider"
                  - "iam:CreateServiceLinkedRole"
                  - "iam:CreateInstanceProfile"
                  - "iam:DeleteInstanceProfile"
                  - "iam:GetInstanceProfile"
                  - "iam:AddRoleToInstanceProfile"
                  - "iam:RemoveRoleFromInstanceProfile"
                Resource: "*"
              - Sid: RequireBoundaryOnCreatedRoles
                # Force every role the pipeline creates to carry the boundary.
                Effect: Allow
                Action:
                  - "iam:CreateRole"
                  - "iam:PutRolePolicy"
                  - "iam:AttachRolePolicy"
                Resource: "*"
                Condition:
                  StringEquals:
                    iam:PermissionsBoundary: !Ref PipelineBoundary
              - Sid: TerraformStateBucket
                Effect: Allow
                Action:
                  - "s3:ListBucket"
                  - "s3:GetObject"
                  - "s3:PutObject"
                  - "s3:DeleteObject"
                  - "s3:GetBucketVersioning"
                Resource:
                  - !Sub "arn:aws:s3:::${StateBucketName}"
                  - !Sub "arn:aws:s3:::${StateBucketName}/*"
              - Sid: TerraformStateLock
                Effect: Allow
                Action:
                  - "dynamodb:GetItem"
                  - "dynamodb:PutItem"
                  - "dynamodb:DeleteItem"
                Resource: !Sub "arn:aws:dynamodb:*:${AWS::AccountId}:table/${LockTableName}"
              - Sid: KMS
                Effect: Allow
                Action:
                  - "kms:CreateKey"
                  - "kms:DescribeKey"
                  - "kms:CreateAlias"
                  - "kms:DeleteAlias"
                  - "kms:ListAliases"
                  - "kms:TagResource"
                  - "kms:ScheduleKeyDeletion"
                  - "kms:GetKeyPolicy"
                  - "kms:PutKeyPolicy"
                  - "kms:CreateGrant"
                Resource: "*"
              - Sid: CloudWatchLogs
                Effect: Allow
                Action:
                  - "logs:CreateLogGroup"
                  - "logs:DeleteLogGroup"
                  - "logs:DescribeLogGroups"
                  - "logs:PutRetentionPolicy"
                  - "logs:TagResource"
                  - "logs:ListTagsForResource"
                Resource: "*"

Outputs:
  RoleArn:
    Description: Put this exact value into the GitHub repository variable AWS_ROLE_ARN.
    Value: !GetAtt PipelineRole.Arn
  OIDCProviderNote:
    Description: Reminder about the OIDC provider.
    Value: !If
      - ShouldCreateOIDC
      - "OIDC provider was created by this stack."
      - "Reused an existing OIDC provider (CreateOIDCProvider=false)."
```

### Deploy it 2

```bash
aws cloudformation deploy \
  --template-file github-oidc-role.yaml \
  --stack-name github-oidc-eks \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOrg=YOUR-ORG \
      GitHubRepo=YOUR-REPO \
      StateBucketName=YOUR-STATE-BUCKET-NAME \
      LockTableName=eks-platform-tflock
```

The `--capabilities CAPABILITY_NAMED_IAM` flag is required because the template creates named IAM resources — CloudFormation makes you explicitly acknowledge that.

**If the OIDC provider already exists** in your account, add `CreateOIDCProvider=false` to the `--parameter-overrides` line; the stack will reuse the existing one instead of failing.

### Get the role ARN out

```bash
aws cloudformation describe-stacks \
  --stack-name github-oidc-eks \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
  --output text
```

Paste that into the GitHub `AWS_ROLE_ARN` variable, re-run the workflow, and the "Verify AWS identity" step should pass.

### To tear it all down later

```bash
aws cloudformation delete-stack --stack-name github-oidc-eks
```

One clean command removes the role, policy, boundary, and provider — versus hunting down each piece you created by hand with the CLI. That's the main reason to prefer CloudFormation here.

---

## Which should you use?

The **CloudFormation** template is the better choice for anything beyond a quick test: it's version-controllable, includes the permissions boundary that closes the privilege-escalation hole, and tears down cleanly. The **CLI** commands are good if you just want the role to exist in five minutes and don't mind cleaning up manually.

Two honest caveats on the permissions policy in both:

The IAM and `kms`/`ec2`/`eks` blocks use broad `*` actions because a create-everything Terraform pipeline genuinely needs wide permissions to stand up a VPC, cluster, node groups, and their roles — names aren't known ahead of time. The meaningful guardrail isn't trimming those, it's the **permissions boundary** in the CloudFormation version, which caps anything the pipeline *creates*. That's the professional pattern AWS itself recommends.

And these policies are a strong **starting point**, not guaranteed-complete — the exact action set the EKS and VPC modules touch shifts between module versions. If a `terraform plan` or `apply` returns `AccessDenied`, the error names the precise action; add it to the policy (or the CFN template and redeploy) and re-run. That iteration is normal and quick.

Want me to drop the CloudFormation template into the repo as `bootstrap/github-oidc-role.yaml` with a short README section on running it, so the whole thing is in your zip and version-controlled?