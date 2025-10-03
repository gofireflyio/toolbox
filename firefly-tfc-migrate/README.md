# TFC to Firefly Migration

A basic tool to migrate Terraform Cloud (TFC) workspaces to Firefly.ai, focusing on workspace data migration with state handling options.

## Overview

This script migrates TFC workspaces to Firefly by:
1. **Scanning** TFC workspaces and projects
2. **Creating** corresponding Firefly projects and workspaces
3. **Migrating** Terraform state (with options for different approaches)
4. **Generating** backend configuration files

## Prerequisites

- Python 3.7+
- Terraform CLI
- TFC/TFE API token
- Firefly API credentials
- AWS credentials (for S3 backend)

## Quick Start

1. **Set up environment variables:**
   ```bash
   export TFC_TOKEN="your-tfc-token"
   export FIREFLY_ACCESS_KEY="your-firefly-access-key"
   export FIREFLY_SECRET_KEY="your-firefly-secret-key"
   export FIREFLY_API_URL="https://api.gofirefly.io"
   ```

2. **Configure VCS integration:**
   - Get your VCS integration ID from Firefly the Firefly engineering team
   - Update `terraform/terraform.tfvars` with the ID

3. **Run migration step by step:**
   ```bash
   # Step 1: Scan TFC workspaces
   python3 1-scan-tfc.py
   
   # Step 2: Generate Terraform configuration
   python3 2-generate-terraform.py
   
   # Step 3: Create Firefly resources
   cd terraform
   terraform init
   terraform plan
   terraform apply
   cd ..
   
   # Step 4: Migrate state (choose one)
   python3 3-migrate-state-simple.py
   # OR
   python3 3-migrate-state-redactor.py
   ```

## Migration Process

### Step 1: Scan TFC Workspaces
```bash
python3 1-scan-tfc.py
```
- Scans all workspaces and projects from TFC
- Exports data to `tfc-workspaces.json`
- Maps TFC projects to Firefly projects

### Step 2: Create Firefly Resources
```bash
cd terraform
terraform init
terraform plan
terraform apply
```
- Creates Firefly projects and workspaces
- Maps TFC workspace data to Firefly format

### Step 3: Migrate State (Choose One Option)

#### Option A: Simple State Migration (Recommended)
```bash
python3 3-migrate-state-simple.py
```
- Uses `terraform state pull` and `terraform init -migrate-state`
- Generates backend configuration files
- Creates workspace-specific README files

#### Option B: States-Redactor (Advanced)
```bash
python3 3-migrate-state-redactor.py
```
- Prepares configuration for states-redactor tool
- Requires Kubernetes or ECS deployment
- Handles sensitive data redaction automatically

## State Migration Options

### Simple State Migration
- **Process**: `terraform state pull` → `terraform init -migrate-state`
- **Pros**: Simple, reliable, standard Terraform approach
- **Cons**: Manual sensitive data handling
- **Backend**: S3 + DynamoDB for state locking

### States-Redactor Tool
- **Process**: K8s CronJob fetches and redacts state files
- **Pros**: Automatic sensitive data redaction, designed for Firefly
- **Cons**: Requires K8s/ECS infrastructure, more complex setup
- **Repository**: https://github.com/gofireflyio/states-redactor

## Backend Configuration

Each migrated workspace gets a `backend.tf` file:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "workspaces/workspace-name/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

## Project Structure

```
firefly-migrate/
├── 1-scan-tfc.py              # Scan TFC workspaces
├── 2-generate-terraform.py    # Generate Terraform config
├── 3-migrate-state-simple.py  # Simple state migration
├── 3-migrate-state-redactor.py # States-redactor approach
├── terraform/                 # Terraform configuration
│   ├── main.tf
│   ├── variables.tf
│   └── terraform.tfvars
└── References/                # Original files backup
```

## Future Capabilities (Blocked until capabilities developed - estimated Q1 2026)

- **User Management**: Adding users to projects via API 
- **Programatic way to pull VCS Integration ID**: Pulling  
- **Variable Migration**: Full variable support when Firefly provider supports it
- **Advanced State Handling**: Option to migrate TF State directly to Firefly

## Troubleshooting

### Common Issues

1. **Terraform Provider Version**: Ensure using `gofireflyio/firefly` v0.0.8+
2. **VCS Integration**: Verify VCS integration ID in Firefly dashboard
3. **State Migration**: Check AWS credentials for S3 backend
4. **User Visibility**: Projects may not be visible in UI until user is added

### Getting Help

- Check Firefly documentation: https://docs.firefly.ai
- States-redactor repo: https://github.com/gofireflyio/states-redactor
- TFC API docs: https://www.terraform.io/docs/cloud/api

## License

MIT License - see LICENSE file for details