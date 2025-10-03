terraform {
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
