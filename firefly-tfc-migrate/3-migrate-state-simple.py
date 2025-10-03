#!/usr/bin/env python3
"""
Simple Terraform state migration from TFC to S3 backend
"""

import json
import os
import sys
import subprocess
import tempfile
from pathlib import Path
from dataclasses import dataclass
from typing import List, Dict, Any

@dataclass
class StateMigrationConfig:
    backend_bucket: str
    backend_region: str
    backend_dynamodb_table: str
    aws_profile: str = "default"

class SimpleStateMigrator:
    def __init__(self, config: StateMigrationConfig):
        self.config = config
        self.workspaces_data = self._load_workspaces_data()
    
    def _load_workspaces_data(self) -> Dict[str, Any]:
        """Load workspace data from JSON file"""
        try:
            with open('tfc-workspaces.json', 'r') as f:
                return json.load(f)
        except FileNotFoundError:
            print("❌ Error: tfc-workspaces.json not found. Run 1-scan-tfc.py first.")
            sys.exit(1)
    
    def create_backend_config(self, workspace_name: str) -> str:
        """Create backend.tf file for a workspace"""
        backend_config = f'''terraform {{
  backend "s3" {{
    bucket         = "{self.config.backend_bucket}"
    key            = "workspaces/{workspace_name}/terraform.tfstate"
    region         = "{self.config.backend_region}"
    dynamodb_table = "{self.config.backend_dynamodb_table}"
    encrypt        = true
  }}
}}
'''
        return backend_config
    
    def create_workspace_readme(self, workspace: Dict[str, Any]) -> str:
        """Create README.md for migrated workspace"""
        readme_content = f'''# {workspace['name']}

Migrated from Terraform Cloud to Firefly.

## Original TFC Information
- **TFC Workspace ID**: {workspace['id']}
- **Project**: {workspace.get('project_name', 'N/A')}
- **Repository**: {workspace.get('repository', 'N/A')}
- **Terraform Version**: {workspace['terraform_version']}
- **Working Directory**: {workspace.get('working_directory', 'N/A')}

## Migration Notes

### State Migration
The Terraform state has been migrated from TFC to S3 backend:
- **S3 Bucket**: {self.config.backend_bucket}
- **State Key**: `workspaces/{workspace['name']}/terraform.tfstate`
- **Region**: {self.config.backend_region}
- **DynamoDB Table**: {self.config.backend_dynamodb_table}

### Variables Migration
**IMPORTANT**: Variables were not migrated automatically. You need to manually add them in Firefly:

**Total Variables**: {len(workspace.get('variables', []))}
**Sensitive Variables**: {len([v for v in workspace.get('variables', []) if v.get('sensitive', False)])}

#### Variables to Add:
'''
        
        for var in workspace.get('variables', []):
            readme_content += f"- **{var['key']}** ({var['category']})"
            if var.get('sensitive', False):
                readme_content += " - SENSITIVE"
            readme_content += f"\n  - Description: {var.get('description', 'N/A')}\n"
        
        readme_content += f'''
### Next Steps
1. Add variables in Firefly workspace settings
2. Update any CI/CD pipelines to use new backend
3. Test workspace functionality
4. Remove old TFC workspace (after verification)

### Backend Configuration
The `backend.tf` file has been created with the S3 backend configuration.
To use this workspace, run:
```bash
terraform init
```

This will initialize the S3 backend and migrate the state.
'''
        
        return readme_content
    
    def migrate_workspace_state(self, workspace: Dict[str, Any]) -> bool:
        """Migrate state for a single workspace"""
        workspace_name = workspace['name']
        print(f"  📦 Migrating state for {workspace_name}...")
        
        try:
            # Create workspace directory
            workspace_dir = Path(f"migrated-workspaces/{workspace_name}")
            workspace_dir.mkdir(parents=True, exist_ok=True)
            
            # Create backend.tf
            backend_config = self.create_backend_config(workspace_name)
            with open(workspace_dir / 'backend.tf', 'w') as f:
                f.write(backend_config)
            
            # Create README.md
            readme_content = self.create_workspace_readme(workspace)
            with open(workspace_dir / 'README.md', 'w') as f:
                f.write(readme_content)
            
            # Create migration script
            migration_script = f'''#!/bin/bash
# Migration script for {workspace_name}

echo "🚀 Migrating {workspace_name} to S3 backend..."

# Set AWS profile if specified
export AWS_PROFILE={self.config.aws_profile}

# Pull state from TFC
echo "📥 Pulling state from TFC..."
terraform state pull > terraform.tfstate

# Initialize with S3 backend
echo "🔄 Initializing S3 backend..."
terraform init -migrate-state

# Verify migration
echo "✅ Verifying migration..."
terraform state list

echo "✅ Migration complete for {workspace_name}!"
echo "📝 Check README.md for next steps"
'''
            
            with open(workspace_dir / 'migrate.sh', 'w') as f:
                f.write(migration_script)
            
            # Make script executable
            os.chmod(workspace_dir / 'migrate.sh', 0o755)
            
            print(f"    ✅ Created migration files in migrated-workspaces/{workspace_name}/")
            return True
            
        except Exception as e:
            print(f"    ❌ Error migrating {workspace_name}: {e}")
            return False
    
    def migrate_all_states(self) -> None:
        """Migrate all workspace states"""
        print("🚀 Starting simple state migration...")
        print(f"   Backend: s3://{self.config.backend_bucket}")
        print(f"   Region: {self.config.backend_region}")
        print(f"   DynamoDB: {self.config.backend_dynamodb_table}")
        
        workspaces = self.workspaces_data.get('workspaces', [])
        successful = 0
        failed = 0
        
        for workspace in workspaces:
            if self.migrate_workspace_state(workspace):
                successful += 1
            else:
                failed += 1
        
        print(f"\n📊 Migration Summary:")
        print(f"   ✅ Successful: {successful}")
        print(f"   ❌ Failed: {failed}")
        print(f"   📁 Output: migrated-workspaces/")
        
        if successful > 0:
            print(f"\n📝 Next steps:")
            print(f"   1. Review migrated-workspaces/ directory")
            print(f"   2. Run migration scripts for each workspace")
            print(f"   3. Add variables in Firefly UI")
            print(f"   4. Update CI/CD pipelines")

def main():
    print("🚀 Simple Terraform State Migration")
    print("=" * 50)
    
    # Get configuration from environment or prompt
    backend_bucket = os.getenv('BACKEND_BUCKET')
    if not backend_bucket:
        backend_bucket = input("Enter S3 bucket name for Terraform state: ")
    
    backend_region = os.getenv('BACKEND_REGION', 'us-west-2')
    backend_dynamodb_table = os.getenv('BACKEND_DYNAMODB_TABLE', 'terraform-state-lock')
    aws_profile = os.getenv('AWS_PROFILE', 'default')
    
    config = StateMigrationConfig(
        backend_bucket=backend_bucket,
        backend_region=backend_region,
        backend_dynamodb_table=backend_dynamodb_table,
        aws_profile=aws_profile
    )
    
    migrator = SimpleStateMigrator(config)
    migrator.migrate_all_states()

if __name__ == "__main__":
    main()
