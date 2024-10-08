### AWS EventBridge Rule cleanup

This Bash script allows you to easily cleanup AWS EventBridge rules created by Firefly across all enabled regions in a given AWS account.

#### Prerequisites

- AWS CLI installed and configured with appropriate permissions

#### Usage

1. Clone this repository:
   ```
   git clone https://github.com/firefly/toolkit.git
   cd toolkit/aws-integration-leftover-cleanup-tool
   ```

2. Make the script executable:
   ```
   chmod +x cleanupFireflyEventBridgeRule.sh
   ```
3. Export AWS Creds:
   ```
   export AWS_ACCESS_KEY_ID="********"
   export AWS_SECRET_ACCESS_KEY="********"
   export AWS_SESSION_TOKEN="********"
   ```
4. Run the script with the required parameters:
   ```
   ./cleanupFireflyEventBridgeRule.sh
   ```

#### What it does

- Validates that you have sufficient permissions to view and delete Eventbridge rules
- Validates which regions are active on your AWS account 
- Deletes all eventBridge rules that match the prefix defined in : DEFAULT_PREFIX="firefly-" in all active regions

#### Error Handling
 
If the default names of the EventBridge rules were changed, please validate that they all have the same prefix and you change it in DEFAULT_PREFIX .
