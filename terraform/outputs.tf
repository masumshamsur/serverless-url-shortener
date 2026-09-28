output "api_endpoint" {
  description = "Base invoke URL for the HTTP API"
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "table_name" {
  description = "DynamoDB table name for links"
  value       = aws_dynamodb_table.links.name
}

output "create_link_function_name" {
  description = "Lambda function name for the create_link handler"
  value       = aws_lambda_function.create_link.function_name
}

output "redirect_function_name" {
  description = "Lambda function name for the redirect handler"
  value       = aws_lambda_function.redirect.function_name
}

output "github_actions_deploy_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC"
  value       = aws_iam_role.github_actions_deploy.arn
}
