# ── IAM user for GitHub Actions → ECR ────────────────────────────────────────
# FORCED EXCEPTION: GitHub OIDC would be the keyless way, but it needs an IAM
# OIDC provider and the Free plan's SCP denies iam:*Provider*. So CI uses a
# dedicated IAM user with a static access key.
#
# - No console access (no login profile; the SCP also denies iam:*LoginProfile*).
# - The access key is NOT created here, so the secret never reaches the Terraform
#   state. It is created out of band with the AWS CLI and loaded straight into
#   GitHub Secrets (see README.md). Because Terraform does not know the key, it
#   must be deleted by hand BEFORE `terraform destroy` (DESTROY.md, step 3).
# - No force_destroy: it makes the provider call iam:DeleteLoginProfile, which the
#   Free plan SCP denies (iam:*LoginProfile*), so the destroy would fail on this user.
# - Least privilege: GetAuthorizationToken (account-wide by design) plus push
#   actions on the three ECR repositories only.

resource "aws_iam_user" "github_ecr_push" {
  name          = "github-ecr-push"
  force_destroy = false

  tags = local.common_tags
}

data "aws_iam_policy_document" "github_ecr_push" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.services : r.arn]
  }
}

resource "aws_iam_user_policy" "github_ecr_push" {
  name   = "ecr-push-flights"
  user   = aws_iam_user.github_ecr_push.name
  policy = data.aws_iam_policy_document.github_ecr_push.json
}
