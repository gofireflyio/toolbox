#!/bin/bash

# Default prefix
DEFAULT_PREFIX="firefly-"

# Function to check AWS permissions
check_permissions() {
    echo "Validating AWS credentials and permissions..."
    
    # Check if AWS CLI is configured
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "Error: Unable to validate AWS credentials. Please check your AWS configuration."
        exit 1
    fi

    # Try to list rules in the default region (or first available region)
    DEFAULT_REGION=$(aws configure get region)
    if [ -z "$DEFAULT_REGION" ]; then
        DEFAULT_REGION=$(aws ec2 describe-regions --query 'Regions[0].RegionName' --output text)
    fi

    if ! aws events list-rules --max-items 1 --region "$DEFAULT_REGION" &> /dev/null; then
        echo "Error: Insufficient permissions to list EventBridge rules."
        echo "Please ensure you have the necessary permissions to manage EventBridge rules."
        exit 1
    fi

    echo "AWS credentials and permissions validated successfully."
}

# Check permissions first
check_permissions

# Use default prefix if no argument is provided
PREFIX=${1:-$DEFAULT_PREFIX}

echo "This script will delete all EventBridge rules with names starting with: $PREFIX"
read -p "Are you sure you want to continue? (y/N): " confirmation

if [[ $confirmation != [yY] ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Get list of all AWS regions
REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text)

for REGION in $REGIONS; do
    echo "Processing region: $REGION"
    
    # List all rules in the region that start with the given prefix
    RULES=$(aws events list-rules --name-prefix "$PREFIX" --region "$REGION" --query 'Rules[].Name' --output text)
    
    for RULE in $RULES; do
        echo "Deleting rule: $RULE in region $REGION"
        
        # List all targets for the rule
        TARGETS=$(aws events list-targets-by-rule --rule "$RULE" --region "$REGION" --query 'Targets[].Id' --output text)
        
        # Remove all targets from the rule
        if [ ! -z "$TARGETS" ]; then
            aws events remove-targets --rule "$RULE" --ids $TARGETS --region "$REGION"
        fi
        
        # Delete the rule
        aws events delete-rule --name "$RULE" --region "$REGION"
        
        echo "Rule $RULE deleted successfully"
    done
done

echo "Process completed."