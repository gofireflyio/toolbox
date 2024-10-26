# AWS Firefly Resources Cleanup

This repository contains AWS CloudFormation templates and Lambda functions for cleaning up Firefly-related AWS resources across all regions in your AWS account.

## Overview

The cleanup process handles the following resources:
- EventBridge (CloudWatch Events) rules with prefix `firefly-events-*` across all enabled regions
- IAM role named `invoke-firefly-remote-event-bus`
- IAM policies with prefix `firefly-readonly-InvokeFireflyEventBusPolicy`

## Prerequisites

- AWS CLI installed and configured
- Appropriate AWS permissions to create Lambda functions and IAM roles

## Repository Structure

```
.
├── README.md
└── cloudformation/
    └── cleanup-lambda.yaml    # CloudFormation template for Lambda deployment
```

## Deployment Instructions

1. Clone this repository:
```bash
git clone [repository-url]
cd [repository-name]
```

2. Deploy using AWS CloudFormation:
```bash
aws cloudformation deploy \
  --template-file cloudformation/cleanup-lambda.yaml \
  --stack-name firefly-cleanup-lambda \
  --capabilities CAPABILITY_IAM
```

3. Invoke the Lambda function:
```bash
aws lambda invoke \
  --function-name $(aws cloudformation describe-stacks \
    --stack-name firefly-cleanup-lambda \
    --query 'Stacks[0].Outputs[?OutputKey==`LambdaArn`].OutputValue' \
    --output text) \
  response.json
```

4. Check the execution results:
```bash
cat response.json
```

## Cleanup Process

The Lambda function performs the following actions:

1. Discovers all enabled AWS regions
2. For each region:
   - Lists all EventBridge rules with prefix `firefly-events-*`
   - Removes all targets from each rule
   - Deletes the rules
3. Removes IAM role:
   - Detaches all policies from the role
   - Deletes inline policies
   - Deletes the role itself
4. Removes IAM policies:
   - Finds policies matching the prefix
   - Detaches them from all entities (users, groups, roles)
   - Deletes all non-default versions
   - Deletes the policies

## Implementation Details

The Lambda function is implemented using:
- Node.js 18.x runtime
- AWS SDK v3 for JavaScript
- 5-minute timeout
- 256MB memory allocation

## CloudWatch Logs

The function logs all operations to CloudWatch Logs. You can find the logs in the CloudWatch Logs console under the log group:
```
/aws/lambda/[stack-name]-CleanupLambda-[random-suffix]
```

## Response Format

The Lambda function returns a JSON response with the following structure:
```json
{
  "statusCode": 200,
  "body": {
    "totalRulesDeleted": 42,
    "rulesByRegion": {
      "us-east-1": 10,
      "eu-west-1": 15,
      // ... other regions
    }
  }
}
```

## Permissions

The CloudFormation template creates a Lambda execution role with the following permissions:
- EventBridge: ListRules, DeleteRule, ListTargetsByRule, RemoveTargets
- EC2: DescribeRegions
- IAM: Various permissions for role and policy management
- CloudWatch Logs: Create log group, Create log stream, Put log events

## Error Handling

- The script continues execution even if individual deletions fail
- All errors are logged to CloudWatch Logs
- The script handles cases where resources might not exist
- Failed deletions don't prevent other resources from being processed

## Cleanup

To remove all deployed resources:
```bash
aws cloudformation delete-stack --stack-name firefly-cleanup-lambda
aws cloudformation wait stack-delete-complete --stack-name firefly-cleanup-lambda
```

## Security Considerations

- The Lambda function requires broad permissions to clean up resources across regions
- Consider implementing additional safeguards based on your security requirements
- Review the IAM permissions before deployment
- All actions are logged to CloudWatch Logs for audit purposes

## Troubleshooting

1. **Lambda Timeout**
   - Default timeout is 10 minutes
   - If cleanup takes longer, modify the `Timeout` property in the CloudFormation template

2. **Permission Issues**
   - Check CloudWatch Logs for specific permission errors
   - Review the IAM role permissions in the CloudFormation template
   - Ensure your AWS account has access to all regions being cleaned

3. **Resource Not Found**
   - The script handles "not found" errors gracefully
   - Check CloudWatch Logs for details about specific resources

4. **Partial Failures**
   - The script continues even if some deletions fail
   - Check CloudWatch Logs for complete details about any failures
