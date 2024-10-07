# Firefly Toolkit
# ![Firefly Logo](firefly.gif)


Welcome to the Firefly Toolkit repository! This collection of tools is designed to assist Firefly customers with various cloud resource management tasks across different cloud providers.

## Table of Contents

- [Firefly Toolkit](#firefly-toolkit)
- [](#)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Tools](#tools)
    - [AWS EventBridge Rule cleanup](#aws-eventbridge-rule-cleanup)
      - [Prerequisites](#prerequisites)
      - [Usage](#usage)
      - [What it does](#what-it-does)
      - [Error Handling](#error-handling)
  - [Contributing](#contributing)
  - [Support](#support)

## Overview

The Firefly Toolkit is a curated set of scripts and utilities that help streamline cloud resource management tasks. These tools are designed to work with various cloud providers, including AWS, Azure, and GCP, and can assist with tasks such as resource cleanup, configuration management, and more.

## Tools

### AWS EventBridge Rule cleanup

This Bash script allows you to easily to cleanup AWS EventBridge rules created by Firefly across all enabled regions in a given AWS account.

#### Prerequisites

- AWS CLI installed and configured with appropriate permissions

#### Usage

1. Clone this repository:
   ```
   git clone https://github.com/firefly/toolkit.git
   cd toolkit
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

If changed the default names of the EventBridge rules. Please validate that they all have the same prefix and you change it in DEFAULT_PREFIX . 

## Contributing

We welcome contributions to the Firefly Toolkit! If you have a script or utility that you think would be valuable to other Firefly customers, please feel free to submit a pull request.

When contributing, please:

1. Ensure your code is well-documented
2. Include a README or update the existing README with usage instructions
3. Test your code thoroughly before submitting

## Support

If you encounter any issues or have questions about using the tools in this repository, please open an issue on GitHub or contact Firefly support.

For more information about Firefly and our services, please visit [our website](https://www.gofirefly.io/).