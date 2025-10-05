#!/usr/bin/env python3
"""
Generate Terraform configuration for Firefly resources
"""

import json
import os
import sys
from pathlib import Path

def generate_terraform_config():
    """Generate Terraform configuration files"""
    print("🔧 Generating Terraform configuration...")
    
    # Read scanned data
    try:
        with open('tfc-workspaces.json', 'r') as f:
            data = json.load(f)
    except FileNotFoundError:
        print("❌ Error: tfc-workspaces.json not found. Run 1-scan-tfc.py first.")
        sys.exit(1)
    
    # Create terraform directory
    terraform_dir = Path('terraform')
    terraform_dir.mkdir(exist_ok=True)
    
    # Generate main.tf
    generate_main_tf(terraform_dir, data)
    
    # Generate variables.tf
    generate_variables_tf(terraform_dir)
    
    # Generate terraform.tfvars
    generate_terraform_tfvars(terraform_dir)
    
    print("✅ Terraform configuration generated in terraform/ directory")

def generate_main_tf(terraform_dir: Path, data: dict):
    """Generate main.tf file"""
    main_tf_content = '''terraform {
  required_version = ">= 1.0"
  required_providers {
    firefly = {
      source  = "gofireflyio/firefly"
      version = "~> 0.0.8"
    }
  }
}

# Configure the Firefly Provider
provider "firefly" {
  access_key = var.firefly_access_key
  secret_key = var.firefly_secret_key
  api_url    = var.firefly_api_url
}

# Read TFC workspace data
locals {
  projects = jsondecode(file("${path.module}/../tfc-workspaces.json")).projects
  workspaces = jsondecode(file("${path.module}/../tfc-workspaces.json")).workspaces
  
  # Create project name mapping
  project_name_mapping = {
    for project in local.projects : project.name => project.id
  }
}

# Create Firefly projects
resource "firefly_workflows_project" "projects" {
  for_each = {
    for project in local.projects : project.id => project
  }
  
  name = each.value.name == "Default Project" ? "default-project" : each.value.name
  description = each.value.description
}

# Create Firefly workspaces
resource "firefly_workflows_runners_workspace" "workspaces" {
  for_each = {
    for ws in local.workspaces : ws.id => ws
  }
  
  name = each.value.name
  description = each.value.description
  
  # Map to Firefly project
  project_id = each.value.project_name != null ? 
    firefly_workflows_project.projects[local.project_name_mapping[each.value.project_name]].id : 
    firefly_workflows_project.projects[local.project_name_mapping["default-project"]].id
  
  # VCS configuration
  vcs_integration_id = var.vcs_integration_id
  vcs_type = each.value.vcs_repo_type
  repository = each.value.repository
  default_branch = each.value.default_branch
  working_directory = each.value.working_directory
  
  # Terraform version (cap at 1.5.7 for Firefly compatibility)
  terraform_version = each.value.terraform_version >= "1.6.0" ? "1.5.7" : each.value.terraform_version
  
  # Tags
  tags = each.value.tag_names != null ? each.value.tag_names : []
  
  # Note: Variables are not supported in current Firefly provider version
  # This will be added when the provider supports it
}

# Outputs
output "projects_created" {
  description = "Number of projects created"
  value = length(firefly_workflows_project.projects)
}

output "workspaces_created" {
  description = "Number of workspaces created"
  value = length(firefly_workflows_runners_workspace.workspaces)
}

output "project_ids" {
  description = "Created project IDs"
  value = {
    for k, v in firefly_workflows_project.projects : v.name => v.id
  }
}

output "workspace_ids" {
  description = "Created workspace IDs"
  value = {
    for k, v in firefly_workflows_runners_workspace.workspaces : v.name => v.id
  }
}

output "workspace_variables_summary" {
  description = "Summary of variables that need manual migration"
  value = {
    for ws in local.workspaces : ws.name => {
      variable_count = length(ws.variables)
      sensitive_count = length([v for v in ws.variables if v.get("sensitive", false)])
      variables = [v["key"] for v in ws.variables]
    }
  }
}
'''
    
    with open(terraform_dir / 'main.tf', 'w') as f:
        f.write(main_tf_content)

def generate_variables_tf(terraform_dir: Path):
    """Generate variables.tf file"""
    variables_tf_content = '''variable "firefly_access_key" {
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
'''
    
    with open(terraform_dir / 'variables.tf', 'w') as f:
        f.write(variables_tf_content)

def generate_terraform_tfvars(terraform_dir: Path):
    """Generate terraform.tfvars file"""
    tfvars_content = '''# Firefly Configuration
# Set these environment variables instead:
# export FIREFLY_ACCESS_KEY="your-access-key"
# export FIREFLY_SECRET_KEY="your-secret-key"
# export FIREFLY_API_URL="https://api.gofirefly.io"

# VCS Integration
# Get this from Firefly dashboard (Settings → Integrations → VCS)
vcs_integration_id = "your-firefly-vcs-integration-id"

# Backend Configuration
backend_bucket    = "your-terraform-state-bucket"
backend_region    = "us-west-2"
backend_dynamodb_table = "terraform-state-lock"
'''
    
    with open(terraform_dir / 'terraform.tfvars', 'w') as f:
        f.write(tfvars_content)

def main():
    print("🚀 Generating Terraform configuration...")
    generate_terraform_config()
    print("\n📝 Next steps:")
    print("1. Update terraform/terraform.tfvars with your VCS integration ID")
    print("2. Set your Firefly credentials as environment variables")
    print("3. Run: cd terraform && terraform init && terraform plan")

if __name__ == "__main__":
    main()
