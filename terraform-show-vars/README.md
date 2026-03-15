# show-vars

A simple CLI tool to display all resolved Terraform / OpenTofu variable values as JSON — before running `plan` or `apply`.

## Problem

There is no built-in `terraform plan --show-variables` or `tofu plan --show-variables` flag. When working with a mix of default values, `.tfvars` files, environment variables (`TF_VAR_*`), and `-var` arguments, it can be hard to know exactly which values will be used.

This script resolves all variables using the same precedence rules as Terraform/OpenTofu and outputs them as clean JSON.

## How It Works

The script:

1. Scans all `.tf` files in the current directory to extract variable names.
2. Pipes them into `terraform console` or `tofu console` which resolves values using the full precedence chain.
3. Uses `jsonencode()` to handle complex types (maps, lists, objects) on a single line.
4. Outputs the result as formatted JSON via `jq`.

Variable values are resolved using the standard precedence order (lowest to highest):

1. `default` values in variable blocks
2. `terraform.tfvars` / `*.auto.tfvars`
3. `TF_VAR_*` / `OPENTOFU_VAR_*` environment variables
4. `-var-file` on command line
5. `-var` on command line

## Requirements

| Tool | Package (Ubuntu/Debian) | Package (RHEL/Amazon Linux) | Pre-installed |
|------|------------------------|-----------------------------|---------------|
| `jq` | `jq` | `jq` | No |
| `grep` | coreutils | coreutils | Yes |
| `sed` | sed | sed | Yes |
| `awk` | gawk | gawk | Yes |
| `paste` | coreutils | coreutils | Yes |
| `tofu` | opentofu | opentofu | No |
| `terraform` | terraform | terraform | No |

You need either `tofu` or `terraform` installed, plus `jq`. Everything else is typically pre-installed on Linux and macOS.

### Install jq

```bash
# Ubuntu/Debian
sudo apt install jq

# RHEL/Amazon Linux
sudo yum install jq

# macOS
brew install jq
```

## Installation

```bash
git clone https://github.com/gofireflyio/toolbox.git
cd terraform-show-vars
chmod +x show-vars.sh
```

Optionally, copy it somewhere in your `PATH`:

```bash
cp show-vars.sh /usr/local/bin/show-vars
```

## Usage

Run the script from within an initialized Terraform/OpenTofu project directory.

```bash
./show-vars.sh [flags]
```

### Flags

| Flag | Description | Default |
|------|-------------|---------|
| `-cmd` | The IaC tool to use | `tofu` |
| `-var-file` | Path to the variables file | `terraform.auto.tfvars` |

### Examples

```bash
# All defaults (tofu + terraform.auto.tfvars)
./show-vars.sh

# Use terraform instead of tofu
./show-vars.sh -cmd terraform

# Specify a var file
./show-vars.sh -var-file prod.tfvars

# Both flags, any order
./show-vars.sh -cmd tofu -var-file prod.tfvars
./show-vars.sh -var-file dev.tfvars -cmd terraform

# No var file exists — falls back to defaults + env vars
./show-vars.sh -var-file nonexistent.tfvars

# Pipe to a file
./show-vars.sh > vars.json

# Silence warnings
./show-vars.sh 2>/dev/null

# Query a specific variable
./show-vars.sh | jq '.aws_region'
```

### Example Output

```json
{
  "aws_region": "us-east-2",
  "cluster_name": "coverage-eks",
  "enable_monitoring": true,
  "node_count": 3,
  "subnet_cidrs": ["10.0.0.32/28", "10.0.0.48/28"],
  "tags": {
    "Demo": "BackupDR",
    "service": "shopping-cart"
  }
}
```

## Error Handling

- Errors and warnings are printed to **stderr**, so stdout is always clean JSON.
- If any error occurs, the script outputs `{}` to stdout.
- Missing var file is a warning (not an error) — the script continues using defaults and environment variables.

## Prerequisites

Before running the script, make sure:

1. You are in a directory containing `.tf` files with variable declarations.
2. You have run `tofu init` or `terraform init`.
3. `jq` is installed.

## Limitations

- The script only scans `.tf` files in the current directory (not subdirectories of modules).
- Variables passed via `-var` on the `tofu plan` / `terraform plan` command line need to be included in your `.tfvars` file or set as `TF_VAR_*` environment variables for this script to pick them up.
- Provider initialization must succeed for `console` to work. If you have credential issues, set mock credentials or use a provider override.

## License

MIT
