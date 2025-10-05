variable "firefly_access_key" {
  description = "Firefly API access key"
  type        = string
  sensitive   = true
}

variable "firefly_secret_key" {
  description = "Firefly API secret key"
  type        = string
  sensitive   = true
}

variable "firefly_api_url" {
  description = "Firefly API URL"
  type        = string
  default     = "https://api.gofirefly.io"
}

variable "vcs_integration_id" {
  description = "Firefly VCS integration ID"
  type        = string
}

variable "backend_bucket" {
  description = "S3 bucket for Terraform state"
  type        = string
}

variable "backend_region" {
  description = "AWS region for S3 backend"
  type        = string
  default     = "us-west-2"
}

variable "backend_dynamodb_table" {
  description = "DynamoDB table for state locking"
  type        = string
}
