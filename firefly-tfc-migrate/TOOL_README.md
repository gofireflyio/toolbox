# Terraform Cloud to Firefly Migration Tool

A comprehensive tool to migrate Terraform Cloud (TFC) workspaces to Firefly.ai, focusing on workspace data migration with flexible state handling options.

## Overview

This migration tool helps organizations transition from Terraform Cloud to Firefly by:
- **Scanning** TFC workspaces and projects
- **Creating** corresponding Firefly projects and workspaces  
- **Migrating** Terraform state with multiple options
- **Generating** backend configuration files

## Features

- ✅ **Complete Workspace Migration**: Projects, workspaces, VCS configuration
- ✅ **Flexible State Migration**: Simple or states-redactor approaches
- ✅ **Variable Handling**: Manual migration with detailed guidance
- ✅ **Backend Configuration**: Automatic S3 backend setup
- ✅ **Security Focused**: No sensitive data in repository
- ✅ **Production Ready**: Comprehensive error handling and validation

## Quick Start

1. **Install Dependencies**
   ```bash
   pip install -r requirements.txt
   ```

2. **Set Environment Variables**
   ```bash
   export TFC_TOKEN="your-tfc-token"
   export TFC_ORG="your-organization"
   export FIREFLY_ACCESS_KEY="your-firefly-access-key"
   export FIREFLY_SECRET_KEY="your-firefly-secret-key"
   export FIREFLY_API_URL="https://api.gofirefly.io"
   ```

3. **Run Migration**
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

## State Migration Options

### Simple State Migration
- Uses standard Terraform `state pull` and `init -migrate-state`
- Manual sensitive data handling
- Best for small to medium migrations

### States-Redactor Approach
- Kubernetes CronJob with automatic sensitive data redaction
- Production-ready with monitoring
- Best for large migrations (50+ workspaces)

## Documentation

- **README.md** - Main documentation
- **SETUP.md** - Detailed setup instructions
- **MIGRATION_ANALYSIS.md** - Technical analysis and recommendations

## Security

- No sensitive data stored in repository
- All credentials use environment variables
- Comprehensive .gitignore for security
- Example files show expected data structure

## Contributing

This tool is part of the Firefly Toolkit. For contributions:
1. Follow the main repository guidelines
2. Test thoroughly before submitting
3. Update documentation as needed

## Support

For issues or questions:
- Open an issue in this repository
- Contact Firefly support
- Review the detailed documentation

## License

Part of the Firefly Toolkit - see main repository for license information.
