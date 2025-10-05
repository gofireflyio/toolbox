#!/usr/bin/env python3
"""
Scan Terraform Cloud workspaces and export to JSON for Firefly migration
"""

import requests
import json
import sys
import os
from dataclasses import dataclass
from typing import List, Optional, Dict, Any

@dataclass
class Project:
    id: str
    name: str
    description: Optional[str] = None

@dataclass
class Workspace:
    id: str
    name: str
    description: Optional[str]
    project_id: Optional[str]
    project_name: Optional[str]
    vcs_repo_type: str
    repository: Optional[str]
    default_branch: Optional[str]
    working_directory: Optional[str]
    terraform_version: str
    tag_names: List[str]
    variables: List[Dict[str, Any]]

class TerraformCloudScanner:
    def __init__(self, tfc_token: str, tfc_url: str = "https://app.terraform.io"):
        self.tfc_token = tfc_token
        self.tfc_url = tfc_url.rstrip('/')
        self.headers = {
            'Authorization': f'Bearer {tfc_token}',
            'Content-Type': 'application/vnd.api+json'
        }
    
    def get_projects(self) -> List[Project]:
        """Fetch all projects from TFC"""
        projects = []
        url = f"{self.tfc_url}/api/v2/organizations/{os.getenv('TFC_ORG')}/projects"
        
        while url:
            response = requests.get(url, headers=self.headers)
            response.raise_for_status()
            data = response.json()
            
            for project_data in data.get('data', []):
                projects.append(Project(
                    id=project_data['id'],
                    name=project_data['attributes']['name'],
                    description=project_data['attributes'].get('description')
                ))
            
            # Handle pagination
            links = data.get('links', {})
            url = links.get('next')
        
        return projects
    
    def get_workspaces(self) -> List[Workspace]:
        """Fetch all workspaces from TFC"""
        workspaces = []
        url = f"{self.tfc_url}/api/v2/organizations/{os.getenv('TFC_ORG')}/workspaces"
        
        while url:
            response = requests.get(url, headers=self.headers)
            response.raise_for_status()
            data = response.json()
            
            for ws_data in data.get('data', []):
                workspaces.append(self._parse_workspace(ws_data))
            
            # Handle pagination
            links = data.get('links', {})
            url = links.get('next')
        
        return workspaces
    
    def _parse_workspace(self, ws_data: Dict[str, Any]) -> Workspace:
        """Parse workspace data from TFC API response"""
        attrs = ws_data['attributes']
        
        # Get VCS repository info
        vcs_repo = attrs.get('vcs-repo', {})
        repository = vcs_repo.get('identifier') if vcs_repo else None
        default_branch = vcs_repo.get('branch') if vcs_repo else None
        working_directory = vcs_repo.get('working-directory') if vcs_repo else None
        
        # Detect VCS type from repository URL
        vcs_type = self._detect_vcs_type(repository) if repository else 'unknown'
        
        # Get project info
        project_id = ws_data['relationships'].get('project', {}).get('data', {}).get('id')
        
        return Workspace(
            id=ws_data['id'],
            name=attrs['name'],
            description=attrs.get('description'),
            project_id=project_id,
            project_name=None,  # Will be filled later
            vcs_repo_type=vcs_type,
            repository=repository,
            default_branch=default_branch,
            working_directory=working_directory,
            terraform_version=attrs.get('terraform-version', '1.5.0'),
            tag_names=attrs.get('tag-names', []),
            variables=[]  # Will be fetched separately
        )
    
    def _detect_vcs_type(self, repository: str) -> str:
        """Detect VCS type from repository URL"""
        if not repository:
            return 'unknown'
        
        repository = repository.lower()
        if 'github.com' in repository:
            return 'github'
        elif 'gitlab.com' in repository or 'gitlab.' in repository:
            return 'gitlab'
        elif 'bitbucket.org' in repository:
            return 'bitbucket'
        elif 'dev.azure.com' in repository or 'visualstudio.com' in repository:
            return 'azure-devops'
        else:
            return 'unknown'
    
    def get_workspace_variables(self, workspace_id: str) -> List[Dict[str, Any]]:
        """Fetch variables for a specific workspace"""
        variables = []
        url = f"{self.tfc_url}/api/v2/workspaces/{workspace_id}/vars"
        
        try:
            response = requests.get(url, headers=self.headers)
            response.raise_for_status()
            data = response.json()
            
            for var_data in data.get('data', []):
                attrs = var_data['attributes']
                variables.append({
                    'key': attrs['key'],
                    'value': attrs.get('value'),
                    'description': attrs.get('description'),
                    'category': attrs['category'],
                    'sensitive': attrs.get('sensitive', False),
                    'hcl': attrs.get('hcl', False)
                })
        except Exception as e:
            print(f"Warning: Could not fetch variables for workspace {workspace_id}: {e}")
        
        return variables
    
    def scan_all_workspaces(self) -> Dict[str, Any]:
        """Scan all workspaces and return complete data"""
        print("🔍 Scanning Terraform Cloud...")
        
        # Get projects first
        print("📁 Fetching projects...")
        projects = self.get_projects()
        print(f"Found {len(projects)} projects")
        
        # Create project mapping
        project_mapping = {p.id: p.name for p in projects}
        
        # Get workspaces
        print("🏗️  Fetching workspaces...")
        workspaces = self.get_workspaces()
        print(f"Found {len(workspaces)} workspaces")
        
        # Update workspace project names and fetch variables
        for workspace in workspaces:
            if workspace.project_id and workspace.project_id in project_mapping:
                workspace.project_name = project_mapping[workspace.project_id]
            else:
                # Fallback naming for workspaces without projects
                workspace.project_name = "default-project"
            
            # Fetch variables
            print(f"  📋 Fetching variables for {workspace.name}...")
            workspace.variables = self.get_workspace_variables(workspace.id)
        
        return {
            'projects': [{'id': p.id, 'name': p.name, 'description': p.description} for p in projects],
            'workspaces': [
                {
                    'id': ws.id,
                    'name': ws.name,
                    'description': ws.description,
                    'project_id': ws.project_id,
                    'project_name': ws.project_name,
                    'vcs_repo_type': ws.vcs_repo_type,
                    'repository': ws.repository,
                    'default_branch': ws.default_branch,
                    'working_directory': ws.working_directory,
                    'terraform_version': ws.terraform_version,
                    'tag_names': ws.tag_names,
                    'variables': ws.variables
                }
                for ws in workspaces
            ]
        }

def main():
    import argparse
    
    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Scan Terraform Cloud workspaces')
    parser.add_argument('--tfc-url', default='https://app.terraform.io', 
                       help='Terraform Cloud/Enterprise URL (default: https://app.terraform.io)')
    args = parser.parse_args()
    
    # Get TFC token from environment
    tfc_token = os.getenv('TFC_TOKEN')
    if not tfc_token:
        print("❌ Error: TFC_TOKEN environment variable not set")
        sys.exit(1)
    
    # Get TFC organization
    tfc_org = os.getenv('TFC_ORG')
    if not tfc_org:
        print("❌ Error: TFC_ORG environment variable not set")
        sys.exit(1)
    
    # Use command line argument or environment variable
    tfc_url = args.tfc_url or os.getenv('TFC_URL', 'https://app.terraform.io')
    
    print(f"🚀 Starting TFC scan...")
    print(f"   Organization: {tfc_org}")
    print(f"   URL: {tfc_url}")
    
    # Create scanner and scan
    scanner = TerraformCloudScanner(tfc_token, tfc_url)
    
    try:
        data = scanner.scan_all_workspaces()
        
        # Export to JSON
        output_file = 'tfc-workspaces.json'
        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"\n✅ Scan complete!")
        print(f"   Projects: {len(data['projects'])}")
        print(f"   Workspaces: {len(data['workspaces'])}")
        print(f"   Output: {output_file}")
        
    except Exception as e:
        print(f"❌ Error during scan: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
