#!/usr/bin/env python3
"""
Prepare configuration for states-redactor tool for Terraform state migration
"""

import json
import os
import sys
import yaml
from pathlib import Path
from dataclasses import dataclass
from typing import List, Dict, Any

@dataclass
class StatesRedactorConfig:
    s3_bucket: str
    s3_region: str
    dynamodb_table: str
    aws_profile: str = "default"
    namespace: str = "firefly"
    schedule: str = "0 2 * * *"  # Daily at 2 AM

class StatesRedactorMigrator:
    def __init__(self, config: StatesRedactorConfig):
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
    
    def create_kubernetes_manifest(self) -> str:
        """Create Kubernetes manifest for states-redactor"""
        manifest = f'''apiVersion: v1
kind: ConfigMap
metadata:
  name: states-redactor-config
  namespace: {self.config.namespace}
data:
  config.yaml: |
    # States Redactor Configuration
    source:
      type: "terraform-cloud"
      token: "$TFC_TOKEN"
      organization: "$TFC_ORG"
      url: "$TFC_URL"
    
    destination:
      type: "s3"
      bucket: "{self.config.s3_bucket}"
      region: "{self.config.s3_region}"
      dynamodb_table: "{self.config.dynamodb_table}"
      aws_profile: "{self.config.aws_profile}"
    
    redaction:
      enabled: true
      patterns:
        - "password"
        - "secret"
        - "key"
        - "token"
        - "credential"
    
    workspaces:
      # Workspaces to migrate (auto-populated)
{self._generate_workspace_list()}

---
apiVersion: v1
kind: Secret
metadata:
  name: states-redactor-secrets
  namespace: {self.config.namespace}
type: Opaque
stringData:
  TFC_TOKEN: "$TFC_TOKEN"
  TFC_ORG: "$TFC_ORG"
  TFC_URL: "$TFC_URL"
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"

---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: states-redactor
  namespace: {self.config.namespace}
spec:
  schedule: "{self.config.schedule}"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: states-redactor
            image: gofireflyio/states-redactor:latest
            envFrom:
            - secretRef:
                name: states-redactor-secrets
            - configMapRef:
                name: states-redactor-config
            volumeMounts:
            - name: config
              mountPath: /app/config
              readOnly: true
          volumes:
          - name: config
            configMap:
              name: states-redactor-config
          restartPolicy: OnFailure
'''
        return manifest
    
    def create_ecs_task_definition(self) -> str:
        """Create ECS task definition for states-redactor"""
        task_definition = {
            "family": "states-redactor",
            "networkMode": "awsvpc",
            "requiresCompatibilities": ["FARGATE"],
            "cpu": "256",
            "memory": "512",
            "executionRoleArn": "arn:aws:iam::ACCOUNT_ID:role/ecsTaskExecutionRole",
            "taskRoleArn": "arn:aws:iam::ACCOUNT_ID:role/states-redactor-role",
            "containerDefinitions": [
                {
                    "name": "states-redactor",
                    "image": "gofireflyio/states-redactor:latest",
                    "essential": True,
                    "environment": [
                        {"name": "TFC_TOKEN", "value": "$TFC_TOKEN"},
                        {"name": "TFC_ORG", "value": "$TFC_ORG"},
                        {"name": "TFC_URL", "value": "$TFC_URL"},
                        {"name": "S3_BUCKET", "value": self.config.s3_bucket},
                        {"name": "S3_REGION", "value": self.config.s3_region},
                        {"name": "DYNAMODB_TABLE", "value": self.config.dynamodb_table}
                    ],
                    "secrets": [
                        {
                            "name": "AWS_ACCESS_KEY_ID",
                            "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:states-redactor/aws-credentials"
                        },
                        {
                            "name": "AWS_SECRET_ACCESS_KEY",
                            "valueFrom": "arn:aws:secretsmanager:REGION:ACCOUNT_ID:secret:states-redactor/aws-credentials"
                        }
                    ],
                    "logConfiguration": {
                        "logDriver": "awslogs",
                        "options": {
                            "awslogs-group": "/ecs/states-redactor",
                            "awslogs-region": self.config.s3_region,
                            "awslogs-stream-prefix": "ecs"
                        }
                    }
                }
            ]
        }
        return json.dumps(task_definition, indent=2)
    
    def create_terraform_module(self) -> str:
        """Create Terraform module for states-redactor ECS deployment"""
        terraform_module = f'''# States Redactor ECS Module
module "states_redactor" {{
  source = "github.com/gofireflyio/states-redactor//terraform/ecs"
  
  name = "states-redactor"
  
  # ECS Configuration
  cluster_name = "firefly-cluster"
  task_cpu    = 256
  task_memory = 512
  
  # Schedule
  schedule_expression = "rate(1 day)"
  
  # Environment Variables
  environment_variables = {{
    TFC_TOKEN = var.tfc_token
    TFC_ORG   = var.tfc_org
    TFC_URL   = var.tfc_url
    S3_BUCKET = "{self.config.s3_bucket}"
    S3_REGION = "{self.config.s3_region}"
    DYNAMODB_TABLE = "{self.config.dynamodb_table}"
  }}
  
  # Secrets
  secrets = {{
    AWS_ACCESS_KEY_ID     = var.aws_access_key_id
    AWS_SECRET_ACCESS_KEY = var.aws_secret_access_key
  }}
  
  # IAM Permissions
  s3_bucket_arn = "arn:aws:s3:::{self.config.s3_bucket}"
  dynamodb_table_arn = "arn:aws:dynamodb:{self.config.s3_region}:ACCOUNT_ID:table/{self.config.dynamodb_table}"
}}

# Variables
variable "tfc_token" {{
  description = "Terraform Cloud API token"
  type        = string
  sensitive   = true
}}

variable "tfc_org" {{
  description = "Terraform Cloud organization"
  type        = string
}}

variable "tfc_url" {{
  description = "Terraform Cloud URL"
  type        = string
  default     = "https://app.terraform.io"
}}

variable "aws_access_key_id" {{
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
}}

variable "aws_secret_access_key" {{
  description = "AWS Secret Access Key"
  type        = string
  sensitive   = true
}}

# Outputs
output "task_definition_arn" {{
  description = "ARN of the ECS task definition"
  value       = module.states_redactor.task_definition_arn
}}

output "cloudwatch_log_group" {{
  description = "CloudWatch log group name"
  value       = module.states_redactor.cloudwatch_log_group
}}
'''
        return terraform_module
    
    def _generate_workspace_list(self) -> str:
        """Generate workspace list for configuration"""
        workspaces = self.workspaces_data.get('workspaces', [])
        workspace_list = ""
        for ws in workspaces:
            workspace_list += f"      - id: {ws['id']}\n"
            workspace_list += f"        name: {ws['name']}\n"
            workspace_list += f"        project: {ws.get('project_name', 'default')}\n"
        return workspace_list
    
    def create_deployment_guide(self) -> str:
        """Create deployment guide for states-redactor"""
        guide = f'''# States-Redactor Deployment Guide

## Overview
The states-redactor tool automatically migrates Terraform state files from TFC to S3, with automatic sensitive data redaction.

## Prerequisites
- Kubernetes cluster OR ECS cluster
- AWS credentials with S3 and DynamoDB permissions
- TFC API token
- S3 bucket: {self.config.s3_bucket}
- DynamoDB table: {self.config.dynamodb_table}

## Deployment Options

### Option 1: Kubernetes CronJob (Recommended)
1. Apply the Kubernetes manifest:
   ```bash
   kubectl apply -f states-redactor-k8s.yaml
   ```

2. Verify deployment:
   ```bash
   kubectl get cronjobs -n {self.config.namespace}
   kubectl logs -n {self.config.namespace} -l app=states-redactor
   ```

### Option 2: ECS Fargate
1. Deploy using Terraform module:
   ```bash
   cd states-redactor-ecs/
   terraform init
   terraform plan
   terraform apply
   ```

2. Verify in ECS console or CloudWatch logs

## Configuration

### Environment Variables
- `TFC_TOKEN`: Terraform Cloud API token
- `TFC_ORG`: Terraform Cloud organization
- `TFC_URL`: Terraform Cloud URL (optional)
- `S3_BUCKET`: {self.config.s3_bucket}
- `S3_REGION`: {self.config.s3_region}
- `DYNAMODB_TABLE`: {self.config.dynamodb_table}

### Workspaces to Migrate
{len(self.workspaces_data.get('workspaces', []))} workspaces will be migrated:
{self._generate_workspace_list()}

## Monitoring
- Check CloudWatch logs for migration progress
- Verify state files in S3 bucket
- Monitor DynamoDB table for state locks

## Troubleshooting
1. Check pod/container logs for errors
2. Verify AWS permissions
3. Confirm TFC token validity
4. Check S3 bucket and DynamoDB table access

## Manual State Migration
If automated migration fails, use the simple migration approach:
```bash
python3 3-migrate-state-simple.py
```
'''
        return guide
    
    def prepare_redactor_deployment(self) -> None:
        """Prepare all files for states-redactor deployment"""
        print("🚀 Preparing states-redactor deployment...")
        
        # Create deployment directory
        deployment_dir = Path('states-redactor-deployment')
        deployment_dir.mkdir(exist_ok=True)
        
        # Create Kubernetes manifest
        k8s_manifest = self.create_kubernetes_manifest()
        with open(deployment_dir / 'states-redactor-k8s.yaml', 'w') as f:
            f.write(k8s_manifest)
        
        # Create ECS task definition
        ecs_task_def = self.create_ecs_task_definition()
        with open(deployment_dir / 'states-redactor-ecs.json', 'w') as f:
            f.write(ecs_task_def)
        
        # Create Terraform module
        terraform_module = self.create_terraform_module()
        with open(deployment_dir / 'states-redactor.tf', 'w') as f:
            f.write(terraform_module)
        
        # Create deployment guide
        guide = self.create_deployment_guide()
        with open(deployment_dir / 'DEPLOYMENT.md', 'w') as f:
            f.write(guide)
        
        print(f"✅ States-redactor deployment files created in {deployment_dir}/")
        print(f"   📁 Kubernetes: states-redactor-k8s.yaml")
        print(f"   📁 ECS: states-redactor-ecs.json")
        print(f"   📁 Terraform: states-redactor.tf")
        print(f"   📁 Guide: DEPLOYMENT.md")

def main():
    print("🚀 States-Redactor Migration Preparation")
    print("=" * 50)
    
    # Get configuration
    s3_bucket = os.getenv('BACKEND_BUCKET')
    if not s3_bucket:
        s3_bucket = input("Enter S3 bucket name for Terraform state: ")
    
    s3_region = os.getenv('BACKEND_REGION', 'us-west-2')
    dynamodb_table = os.getenv('BACKEND_DYNAMODB_TABLE', 'terraform-state-lock')
    aws_profile = os.getenv('AWS_PROFILE', 'default')
    namespace = os.getenv('K8S_NAMESPACE', 'firefly')
    schedule = os.getenv('CRON_SCHEDULE', '0 2 * * *')
    
    config = StatesRedactorConfig(
        s3_bucket=s3_bucket,
        s3_region=s3_region,
        dynamodb_table=dynamodb_table,
        aws_profile=aws_profile,
        namespace=namespace,
        schedule=schedule
    )
    
    migrator = StatesRedactorMigrator(config)
    migrator.prepare_redactor_deployment()
    
    print(f"\n📝 Next steps:")
    print(f"   1. Review states-redactor-deployment/ directory")
    print(f"   2. Choose deployment method (K8s or ECS)")
    print(f"   3. Update configuration with your values")
    print(f"   4. Deploy and monitor migration")

if __name__ == "__main__":
    main()
