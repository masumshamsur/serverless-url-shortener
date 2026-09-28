data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github_actions.arn]
    }

    # The token must have been requested for AWS STS specifically
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only workflow runs from pushes to main, in exactly this repo.
    # Note: GitHub's sub claim is ID-qualified (owner@ownerId/repo@repoId),
    # not just plain names - confirmed by decoding a real token (see
    # docs/phase-3-cicd.md Step 4 for how). This format is actually more
    # robust: it survives a repo or username rename since the numeric IDs
    # never change, unlike a plain-name match would.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:masumshamsur@128269966/serverless-url-shortener@1388368455:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "${var.project_name}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}

# Only permission granted: update the code of exactly these two functions.
# No InvokeFunction, no config changes, no other Lambda functions, nothing else.
data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    effect  = "Allow"
    actions = ["lambda:UpdateFunctionCode"]
    resources = [
      aws_lambda_function.create_link.arn,
      aws_lambda_function.redirect.arn,
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "${var.project_name}-github-actions-deploy"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}
