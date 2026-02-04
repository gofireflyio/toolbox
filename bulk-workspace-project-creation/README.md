# Bulk Workspace Creation for Firefly

This repository contains two Python scripts that work together to automatically create Firefly workspaces and projects from GitHub repositories containing Terraform files.

## Overview

1. **`get_github_mapping.py`** - Scans GitHub repositories and creates a mapping of directories that contain `.tf` files
2. **`workscpae_and_project_creation.py`** - Creates Firefly workspaces and projects based on the directory mapping

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Script 1: GitHub Directory Mapping](#script-1-github-directory-mapping)
- [Script 2: Firefly Workspace Creation](#script-2-firefly-workspace-creation)
- [Complete Workflow Example](#complete-workflow-example)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before you begin, ensure you have:

- **Python 3.6+** installed
- **`requests` library** installed (`pip install requests`)
- **GitHub account** with access to the repositories you want to map
- **Firefly account** with API access
- **Firefly API credentials** (Access Key and Secret Key)
- **VCS Integration** configured in Firefly (GitHub, GitLab, etc.)

### Installing Dependencies

```bash
pip install requests
```

---

## Script 1: GitHub Directory Mapping

### What It Does

The `get_github_mapping.py` script:
- Scans GitHub repositories using the GitHub API
- **Only includes directories that contain `.tf` files** (Terraform files)
- Includes all parent directories leading to directories with `.tf` files
- Excludes leaf directories that don't have `.tf` files
- Generates a JSON mapping file (`github_directory_mapping.json`)

### Directory Filtering Logic

The script uses intelligent filtering to only include relevant directories:

**Example Structure:**
```
aws/
  production/
    main.tf          ← Has .tf file, INCLUDED
  staging/
    main.tf          ← Has .tf file, INCLUDED
  docs/
    README.md        ← No .tf files, EXCLUDED
```

**Result:** Only `aws`, `aws/production`, and `aws/staging` are included in the mapping.

**Key Rules:**
- ✅ Directories with `.tf` files are included
- ✅ Parent directories leading to `.tf` files are included
- ❌ Leaf directories without `.tf` files are excluded
- ❌ Hidden directories (starting with `.`) are excluded

### Getting Your GitHub Token

#### Step 1: Create a GitHub Personal Access Token

1. Go to [GitHub Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens/new)
2. Click **Generate new token (classic)**
3. Give it a descriptive name (e.g., "Firefly Workspace Mapping")
4. Select expiration (30 days, 90 days, or no expiration)
5. Select scopes:
   - **For public repos only**: No scopes needed
   - **For private repos**: Check `repo` scope
6. Click **Generate token**
7. **⚠️ IMPORTANT**: Copy the token immediately - you won't see it again!
   - Tokens start with `ghp_` (classic tokens)
8. **Note**: You can delete this token immediately after generating the `github_directory_mapping.json` file, as it's only needed for the initial directory mapping step.
8. **Note**: You can delete this token immediately after generating the `github_directory_mapping.json` file, as it's only needed for the initial directory mapping step.

#### Step 2: Configure the Script

Edit `get_github_mapping.py` and set:

```python
# Line 18: Set your GitHub token
GITHUB_TOKEN = "ghp_your_actual_token_here"

# Lines 21-23: Set repositories to map
REPOS_TO_MAP = [
    "owner/repo",           # Individual repository
    "owner/repo2",          # Another repository
    "owner"                 # Entire organization (maps all repos)
]
```

**Repository Format Options:**
- `"owner/repo"` - Individual repository
- `"owner"` - Entire organization (maps all repos)
- `"https://github.com/owner/repo"` - Full GitHub URL
- `"https://github.com/owner"` - Organization URL

**Example:**
```python
REPOS_TO_MAP = [
    "Firefly-SE/infrastructure",
    "Firefly-SE/terraform-modules",
    "Firefly-SE"  # Maps all repos in the organization
]
```

### Running the Script

```bash
python get_github_mapping.py
```

**Output:**
- Creates `github_directory_mapping.json` with the directory structure
- Displays progress in the console
- Shows summary of directories mapped

**Example Output:**
```
============================================================
Fetching directory mapping for: Firefly-SE/infrastructure
============================================================
Total directories mapped: 12

Mapping saved to: github_directory_mapping.json
```

### Output Format

The generated JSON file has a nested structure:

```json
{
  "Firefly-SE/infrastructure": {
    "aws": {
      "production": {},
      "staging": {}
    },
    "gcp": {
      "dev": {}
    }
  }
}
```

Empty objects `{}` represent leaf directories (directories with no subdirectories that contain `.tf` files).

---

## Script 2: Firefly Workspace Creation

### What It Does

The `workscpae_and_project_creation.py` script:
- Reads the `github_directory_mapping.json` file
- Authenticates with Firefly API using v2 authentication
- Creates Firefly workspaces for each leaf directory (directories with `.tf` files)
- Optionally creates Firefly projects that mirror the directory structure
- Attaches workspaces to their corresponding projects
- Generates a results file (`firefly_workflows_created.json`)

### Getting Your Firefly Credentials

#### Step 1: Get Firefly Access Key and Secret Key

1. **Log in to Firefly**
   - Go to your Firefly URL: https://app.firefly.ai
   - Sign in to your account

2. **Navigate to Settings**
   - Click on **Settings** in the navigation menu

3. **Go to Users Section**
   - Click on **Access Managements** in the settings menu

4. **Create Key Pair**
   - Click on **Create Key Pair** button
   - A dialog will appear with:
     - **Access Key** (public identifier)
     - **Secret Key** (private key - shown only once!)
   - **⚠️ CRITICAL**: Copy both keys immediately and store them securely
   - You will NOT be able to see the Secret Key again after closing the dialog

5. **Store Keys Securely**
   - Save in a password manager
   - Never commit to version control
   - Consider using environment variables for production use

#### Step 2: Get VCS Integration ID

The VCS Integration ID identifies your connected GitHub/GitLab/etc. integration in Firefly.

**Open Firefly**
   - Navigate to **Settings** → **Integrations** (or **VCS Integrations**) → The integration ID will be mentioned under the Integration itself


### Configuring the Script

Edit `workscpae_and_project_creation.py` and configure the following:

#### Required Configuration

```python
# Lines 19-20: Firefly API Authentication
ACCESS_KEY = "your-access-key-here"      # From Firefly Settings → Users
SECRET_KEY = "your-secret-key-here"      # From Firefly Settings → Users

# Line 23: VCS Integration ID
VCS_ID = "your-vcs-integration-id-here"  # From Firefly Settings → Integrations

# ⚠️ IMPORTANT: Replace all placeholder values ("ACCESS_KEY", "SECRET_KEY", "VCS_ID", "VCS_TYPE") 
# with your actual credentials before running the script!
```

#### VCS Configuration

```python
# Line 25: VCS Type (must match your integration type)
VCS_TYPE = "github"  # Options: "github", "gitlab", "bitbucket", "codecommit", "azuredevops"
# Note: Replace "github" with your actual VCS type (e.g., "bitbucket", "gitlab")

# Line 26: Default branch name
DEFAULT_BRANCH = "main"  # Change to "master" or your default branch
```

#### Workspace Configuration

```python
# Lines 32-34: Runner and IAC Configuration
RUNNER_TYPE = "RUNNER_TYPE"           # See valid options below
IAC_TYPE = "terraform"             # Infrastructure as Code type
TERRAFORM_VERSION = "1.5.7"       # Terraform version to use
```

**Valid Runner Types:**
- `"github-actions"` - GitHub Actions
- `"gitlab-pipelines"` - GitLab CI/CD
- `"bitbucket-pipelines"` - Bitbucket Pipelines
- `"azure-pipelines"` - Azure DevOps Pipelines
- `"jenkins"` - Jenkins
- `"semaphore"` - Semaphore CI
- `"atlantis"` - Atlantis
- `"env0"` - Env0
- `"firefly"` - Firefly runners (default)
- `"unrecognized"` - Unrecognized CI/CD systems

#### Execution Configuration

```python
# Line 37: Execution Triggers
EXECUTION_TRIGGERS = ["merge"]  # Options: ["merge"], ["push"], ["pull_request"], or combinations

# Line 38: Apply Rule
APPLY_RULE = "manual"  # Options: "manual" (requires approval), "auto" (automatic)
```

**Trigger Options:**
- `["merge"]` - Trigger on merge to default branch
- `["push"]` - Trigger on push to default branch
- `["pull_request"]` - Trigger on pull requests
- `["merge", "push"]` - Multiple triggers

#### Workspace Variables (Optional)

```python
# Lines 41-49: Workspace Variables
WORKSPACE_VARIABLES = [
    {
        "key": "ENV",
        "value": "production",
        "sensitivity": "string",  # Options: "string", "secret"
        "destination": "env"      # Options: "env", "iac"
    },
    {
        "key": "AWS_REGION",
        "value": "us-east-1",
        "sensitivity": "string",
        "destination": "env"
    }
]
```

**Variable Fields:**
- `key`: Variable name (required)
- `value`: Variable value (required)
- `sensitivity`: `"string"` (regular) or `"secret"` (masked)
- `destination`: `"env"` (environment variable) or `"iac"` (IaC variable)

#### Project Configuration

```python
# Line 56: Enable/Disable Project Creation
CREATE_PROJECTS = True  # Set to True to create projects that mirror directory structure

# Line 52: Global Project ID (used when CREATE_PROJECTS is False)
PROJECT_ID = None  # Set to a project ID to assign all workspaces to one project, or None for global
```

**When `CREATE_PROJECTS = True`:**
- Creates a main project for each repository
- Creates sub-projects for each directory level
- Automatically attaches workspaces to their corresponding projects
- Projects mirror the directory structure

**When `CREATE_PROJECTS = False`:**
- No projects are created
- Workspaces are created at the global level (or assigned to `PROJECT_ID` if set)

#### Project Members Configuration

You can automatically attach users to projects with specific roles. This is useful for setting up access control when projects are created.

**Main Project Members:**

Attach users to the main project (root project for each repository):

```python
# Lines 64-75: Users to attach to main projects
# Format: List of dictionaries with "userId" and "role" keys
MAIN_PROJECT_MEMBERS = [
    {
        "userId": "user-id-1",
        "role": "admin"
    },
    {
        "userId": "user-id-2",
        "role": "member"
    }
]
```

**Path-Specific Project Members:**

Attach users to specific projects based on their directory path:

```python
# Lines 77-100: Users to attach to specific projects by path
# Format: Dictionary mapping directory paths to lists of user dictionaries
PROJECT_PATH_MEMBERS = {
    "/aws/production": [
        {
            "userId": "user-id-1",
            "role": "admin"
        },
        {
            "userId": "user-id-2",
            "role": "member"
        }
    ],
    "/gcp/staging": [
        {
            "userId": "user-id-3",
            "role": "admin"
        }
    ]
}
```

**How to Get User IDs:**

1. **Using Firefly API:**
   ```bash
   curl -X GET "https://api.firefly.ai/v2/users" \
     -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
   ```

2. **Using Browser Developer Tools:**
   - Open Firefly dashboard
   - Navigate to **Settings** → **Users**
   - Open Developer Tools (F12) → **Network** tab
   - Look for API requests to `/v2/users` or `/api/v2/users`
   - Find the `id` field in the response

**Role Options:**
- `"admin"` - Full access to the project
- `"member"` - Standard member access
- `"viewer"` - Read-only access
- (Check Firefly API documentation for all available roles)

**Path Format:**
- Use work directory format with leading slash: `/aws/production`
- Paths must match the directory structure in your mapping
- The script will automatically normalize paths to match project paths

#### Project Variables Configuration

You can automatically attach variables to projects. This is useful for setting environment-specific or project-specific configuration.

**Main Project Variables:**

Attach variables to the main project (root project for each repository):

```python
# Lines 102-115: Variables to attach to main projects
# Format: List of variable dictionaries with "key", "value", "sensitivity", and "destination" keys
MAIN_PROJECT_VARIABLES = [
    {
        "key": "ENV",
        "value": "production",
        "sensitivity": "string",  # Options: "string", "secret"
        "destination": "env"      # Options: "env", "iac"
    },
    {
        "key": "AWS_REGION",
        "value": "us-east-1",
        "sensitivity": "string",
        "destination": "env"
    }
]
```

**Path-Specific Project Variables:**

Attach variables to specific projects based on their directory path:

```python
# Lines 117-145: Variables to attach to specific projects by path
# Format: Dictionary mapping directory paths to lists of variable dictionaries
PROJECT_PATH_VARIABLES = {
    "/aws/production": [
        {
            "key": "ENV",
            "value": "production",
            "sensitivity": "string",
            "destination": "env"
        },
        {
            "key": "AWS_REGION",
            "value": "us-east-1",
            "sensitivity": "string",
            "destination": "env"
        }
    ],
    "/gcp/staging": [
        {
            "key": "ENV",
            "value": "staging",
            "sensitivity": "string",
            "destination": "env"
        },
        {
            "key": "GCP_PROJECT",
            "value": "my-staging-project",
            "sensitivity": "string",
            "destination": "env"
        }
    ]
}
```

**Variable Fields:**
- `key`: Variable name (required)
- `value`: Variable value (required)
- `sensitivity`: `"string"` (regular) or `"secret"` (masked)
- `destination`: `"env"` (environment variable) or `"iac"` (IaC variable)

**Path Format:**
- Use work directory format with leading slash: `/aws/production`
- Paths must match the directory structure in your mapping
- The script will automatically normalize paths to match project paths

#### Additional Configuration

```python
# Line 53: Variable Sets (Optional)
CONSUMED_VARIABLE_SETS = []  # Array of variable set IDs to attach to workspaces

# Line 63: Input/Output Files
MAPPING_JSON_FILE = "github_directory_mapping.json"  # Input file from script 1
OUTPUT_LOG_FILE = "firefly_workflows_created.json"   # Output file with results
```

### Running the Script

```bash
python workscpae_and_project_creation.py
```

**What Happens:**
1. Authenticates with Firefly API (v2) using your Access Key and Secret Key
2. Loads `github_directory_mapping.json`
3. For each repository:
   - Creates project structure (if `CREATE_PROJECTS = True`)
   - Attaches members to main projects (if `MAIN_PROJECT_MEMBERS` is configured)
   - Attaches variables to main projects (if `MAIN_PROJECT_VARIABLES` is configured)
   - Creates sub-projects for each directory level
   - Attaches members to specific projects by path (if `PROJECT_PATH_MEMBERS` is configured)
   - Attaches variables to specific projects by path (if `PROJECT_PATH_VARIABLES` is configured)
   - Creates workspaces for each leaf directory
   - Attaches workspaces to their corresponding projects
4. Saves results to `firefly_workflows_created.json`

---

### Verify in Firefly Dashboard

1. Log in to your Firefly
2. Navigate to **Workspaces** to see created workspaces
3. Navigate to **Projects** to see created projects (if `CREATE_PROJECTS = True`)
4. Verify workspaces are attached to correct projects

---

## Configuration Reference

### get_github_mapping.py Configuration

| Variable | Type | Required | Description |
|----------|------|----------|-------------|
| `GITHUB_TOKEN` | string | Yes* | GitHub Personal Access Token (*required for private repos) |
| `REPOS_TO_MAP` | list | Yes | List of repositories/organizations to map |

### workscpae_and_project_creation.py Configuration

#### Required Variables

| Variable | Type | Description |
|----------|------|-------------|
| `ACCESS_KEY` | string | Firefly Access Key (from Settings → Users) |
| `SECRET_KEY` | string | Firefly Secret Key (from Settings → Users) |
| `VCS_ID` | string | VCS Integration ID (from Settings → Integrations) |
| `VCS_TYPE` | string | VCS type: `"github"`, `"gitlab"`, `"bitbucket"`, `"codecommit"`, `"azuredevops"` (must match your integration type) |
| `DEFAULT_BRANCH` | string | Default branch name for repositories |
| `RUNNER_TYPE` | string | Runner type (see valid options above) |
| `IAC_TYPE` | string | Infrastructure as Code type |
| `TERRAFORM_VERSION` | string | Terraform version to use |
| `EXECUTION_TRIGGERS` | list | When to trigger runs: `["merge"]`, `["push"]`, `["pull_request"]` |
| `APPLY_RULE` | string | Apply rule: `"manual"` or `"auto"` |

#### Optional Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `WORKSPACE_VARIABLES` | list | `[]` | Array of workspace variables |
| `CREATE_PROJECTS` | bool | `True` | Create projects that mirror directory structure |
| `PROJECT_ID` | string/None | `None` | Global project ID (used when `CREATE_PROJECTS = False`) |
| `MAIN_PROJECT_MEMBERS` | list | `[]` | Users to attach to main projects (list of dicts with `userId` and `role`) |
| `PROJECT_PATH_MEMBERS` | dict | `{}` | Users to attach to specific projects by path (dict mapping paths to user lists) |
| `MAIN_PROJECT_VARIABLES` | list | `[]` | Variables to attach to main projects (list of dicts with `key`, `value`, `sensitivity`, `destination`) |
| `PROJECT_PATH_VARIABLES` | dict | `{}` | Variables to attach to specific projects by path (dict mapping paths to variable lists) |
| `CONSUMED_VARIABLE_SETS` | list | `[]` | Array of variable set IDs |
| `MAPPING_JSON_FILE` | string | `"github_directory_mapping.json"` | Input JSON file |
| `OUTPUT_LOG_FILE` | string | `"firefly_workflows_created.json"` | Output results file |

---

## Security Best Practices

1. **Never commit credentials to version control**
   - ⚠️ **CRITICAL**: Always replace placeholder values (`"ACCESS_KEY"`, `"SECRET_KEY"`, `"VCS_ID"`, `"VCS_TYPE"`) with actual values
   - Use environment variables for production
   - Add `.env` files to `.gitignore`
   - Use secrets management tools
   - Never commit actual API keys or tokens

2. **Store tokens securely**
   - Use password managers
   - Rotate tokens regularly
   - Use fine-grained tokens when possible
   - Firefly Secret Keys are shown only once - store them immediately

3. **Limit token scopes**
   - Only grant necessary permissions
   - Use read-only tokens when possible
   - GitHub tokens: Only grant `repo` scope if accessing private repos

4. **Review created workspaces**
   - Verify workspaces are created correctly
   - Check project assignments
   - Review workspace configurations
   - Verify project members and variables are attached correctly

5. **Validate configuration before running**
   - Double-check all placeholder values are replaced
   - Verify `VCS_TYPE` matches your actual integration type
   - Test with a single repository first

---

## License

This script is provided as-is for Firefly workflow automation purposes.