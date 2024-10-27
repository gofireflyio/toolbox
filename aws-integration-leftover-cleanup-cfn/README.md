# AWS Firefly Resources Cleanup

This repository contains an AWS CloudFormation template for deploying a Lambda function that cleans up Firefly-related AWS resources across all regions in your AWS account.

## Overview

The cleanup process automatically removes the following resources:
- EventBridge (CloudWatch Events) rules with prefix `firefly-events-*` across all enabled regions
- IAM role named `invoke-firefly-remote-event-bus`
- IAM policies with prefix `firefly-readonly-InvokeFireflyEventBusPolicy`

## Prerequisites

- AWS CLI installed and configured
- Appropriate AWS permissions to create/manage:
  - CloudFormation stacks
  - Lambda functions
  - IAM roles and policies
  - EventBridge rules
  - CloudWatch Logs

## Repository Structure

```
.
├── README.md
└── template.yaml    # CloudFormation template for the cleanup solution
```

## Deployment

1. Clone this repository:
```bash
git clone [repository-url]
cd [repository-name]
```

2. Deploy using AWS CloudFormation:
```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name firefly-cleanup \
  --capabilities CAPABILITY_IAM
```

The stack will automatically trigger the cleanup process during deployment. No additional invocation is needed.

## Implementation Details

### Lambda Function

- Runtime: Node.js 18.x
- Memory: 256MB
- Timeout: 10 minutes
- Uses AWS SDK v3 for JavaScript
- Implements CloudFormation Custom Resource pattern

### Cleanup Process

The Lambda function performs these operations in sequence:

1. **Region Discovery**
   - Identifies all enabled AWS regions in the account

2. **EventBridge Rules Cleanup (per region)**
   - Lists rules with prefix `firefly-events-*`
   - Removes all targets from each rule
   - Deletes the rules

3. **IAM Role Cleanup**
   - Detaches managed policies
   - Removes inline policies
   - Deletes the role `invoke-firefly-remote-event-bus`

4. **IAM Policy Cleanup**
   - Identifies policies matching the prefix
   - Detaches from all entities (users, groups, roles)
   - Removes policy versions
   - Deletes the policies

### CloudWatch Logs

Logs are available in CloudWatch under:
```
/aws/lambda/[stack-name]-CleanupLambda-[random-suffix]
```

### Response Format

The cleanup operation returns a summary in this format:
```json
{
  "totalRulesDeleted": <number>,
  "rulesByRegion": {
    "region1": <number>,
    "region2": <number>
  }
}
```

## IAM Permissions

The Lambda function's execution role includes permissions for:
- EventBridge operations (ListRules, DeleteRule, etc.)
- EC2 DescribeRegions
- IAM role and policy management
- CloudWatch Logs

## Error Handling

The implementation includes robust error handling:
- Continues execution if individual deletions fail
- Handles non-existent resources gracefully
- Logs all operations and errors
- Returns appropriate responses to CloudFormation

## Stack Cleanup

To remove all deployed resources:
```bash
aws cloudformation delete-stack --stack-name firefly-cleanup
aws cloudformation wait stack-delete-complete --stack-name firefly-cleanup
```

## Troubleshooting

### Common Issues

1. **Stack Creation Failed**
   - Check CloudWatch Logs for detailed error messages
   - Verify IAM permissions
   - Ensure all required resources are accessible

2. **Cleanup Incomplete**
   - Review CloudWatch Logs for specific failures
   - Check for permission issues
   - Verify resource existence and accessibility

3. **Timeout Issues**
   - Default timeout is 10 minutes
   - For large deployments, consider increasing the Lambda timeout in the template

### Getting Help

1. Check CloudWatch Logs for detailed error messages
2. Review the CloudFormation stack events
3. Verify AWS CLI configuration and permissions

## Security Considerations

- The Lambda function requires permissions across multiple AWS services
- All actions are logged for audit purposes
- Consider implementing additional safeguards:
  - Resource tagging
  - Additional prefix restrictions
  - Regional restrictions