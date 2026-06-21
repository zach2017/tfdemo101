# TFLint configuration. The AWS ruleset adds AWS-specific checks (deprecated
# instance types, invalid ARNs, etc.) on top of the core Terraform rules.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
