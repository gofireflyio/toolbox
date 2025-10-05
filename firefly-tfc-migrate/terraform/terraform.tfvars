# Firefly Configuration
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
