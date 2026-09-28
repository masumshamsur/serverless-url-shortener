# --- create_link function ---

data "archive_file" "create_link" {
  type        = "zip"
  source_dir  = "${path.module}/../src/create_link"
  output_path = "${path.module}/build/create_link.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "create_link" {
  name              = "/aws/lambda/${var.project_name}-create-link"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "create_link" {
  function_name    = "${var.project_name}-create-link"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "app.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.create_link.output_path
  source_code_hash = data.archive_file.create_link.output_base64sha256
  timeout          = 5

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.links.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.create_link]
}

# --- redirect function ---

data "archive_file" "redirect" {
  type        = "zip"
  source_dir  = "${path.module}/../src/redirect"
  output_path = "${path.module}/build/redirect.zip"
  excludes    = ["__pycache__"]
}

resource "aws_cloudwatch_log_group" "redirect" {
  name              = "/aws/lambda/${var.project_name}-redirect"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "redirect" {
  function_name    = "${var.project_name}-redirect"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "app.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.redirect.output_path
  source_code_hash = data.archive_file.redirect.output_base64sha256
  timeout          = 5

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.links.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.redirect]
}
