# Setup Guide

## Prerequisites

Before running the migration, ensure you have:

1. **Python 3.7+** installed
2. **Terraform CLI** installed
3. **TFC/TFE API token** with appropriate permissions
4. **Firefly API credentials** (access key and secret key)
5. **VCS Integration ID** from Firefly dashboard
6. **AWS credentials** (for S3 backend, if using state migration)

## Quick Setup

### 1. Install Dependencies
```bash
pip install -r requirements.txt
```

### 2. Set Environment Variables
```bash
# TFC/TFE Configuration
export TFC_TOKEN="your-tfc-token"
export TFC_ORG="your-organization"

# Firefly Configuration
export FIREFLY_ACCESS_KEY="your-firefly-access-key"
export FIREFLY_SECRET_KEY="your-firefly-secret-key"
export FIREFLY_API_URL="https://api.gofirefly.io"

# Backend Configuration (for state migration)
export BACKEND_BUCKET="your-terraform-state-bucket"
export BACKEND_REGION="us-west-2"
export BACKEND_DYNAMODB_TABLE="terraform-state-lock"
```

### 3. Configure VCS Integration
1. Go to Firefly dashboard
2. Navigate to **Settings → Integrations → VCS**
3. Copy the VCS integration ID
4. Update `terraform/terraform.tfvars` with the ID

### 4. Run Migration
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

## File Structure

```
firefly-migrate/
├── 1-scan-tfc.py                    # Scan TFC workspaces
├── 2-generate-terraform.py          # Generate Terraform config
├── 3-migrate-state-simple.py        # Simple state migration
├── 3-migrate-state-redactor.py      # States-redactor approach
├── README.md                        # Main documentation
├── MIGRATION_ANALYSIS.md            # Detailed analysis
├── requirements.txt                 # Python dependencies
├── tfc-workspaces.json.example      # Example workspace data
├── terraform/                       # Terraform configuration
│   ├── main.tf
│   ├── variables.tf
│   └── terraform.tfvars
└── References/                      # Original files backup
```

## Security Notes

- **Never commit sensitive data** (tokens, credentials, state files)
- **Use environment variables** for all sensitive configuration
- **Review .gitignore** to ensure sensitive files are excluded
- **Rotate credentials** after migration is complete

## Troubleshooting

### Common Issues

1. **401 Unauthorized**: Check TFC token validity and permissions
2. **404 Not Found**: Verify organization name and API endpoints
3. **Terraform errors**: Ensure Firefly provider version compatibility
4. **State migration issues**: Check AWS credentials and S3 bucket access

### Getting Help

- Check the main README.md for detailed instructions
- Review MIGRATION_ANALYSIS.md for technical details
- Verify all environment variables are set correctly
