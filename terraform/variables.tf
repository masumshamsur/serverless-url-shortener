variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix used for naming resources"
  type        = string
  default     = "url-shortener"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for Lambda functions"
  type        = number
  default     = 14
}
