#!/usr/bin/env python3
"""
Script to create Firefly workflows from GitHub directory mapping.
Reads the GitHub directory mapping JSON and creates a Firefly workspace for each subdirectory.
"""

import json
import sys
from typing import Dict, Any, List, Optional
import requests


# ============================================================================
# Firefly API Configuration - Hardcoded values (modify as needed)
# ============================================================================

# Firefly API Authentication
FIREFLY_API_BASE_URL = "https://api.firefly.ai"
ACCESS_KEY = "ACCESS_KEY"  # Replace with your actual Firefly access key
SECRET_KEY = "SECRET_KEY"  # Replace with your actual Firefly secret key

# VCS Configuration
VCS_ID = "VCS_ID"  # Replace with your VCS integration ID
# VCS Type options: "github", "gitlab", "bitbucket", "codecommit", "azuredevops"
VCS_TYPE = "VCS_TYPE"
DEFAULT_BRANCH = "main"  # Default branch for repositories

# Workspace Configuration
# Runner Type options: "github-actions", "gitlab-pipelines", "bitbucket-pipelines", 
#                      "azure-pipelines", "jenkins", "semaphore", "atlantis", 
#                      "env0", "firefly", "unrecognized"
RUNNER_TYPE = "firefly"
IAC_TYPE = "terraform"  # Infrastructure as Code type
TERRAFORM_VERSION = "1.5.7"  # Terraform version to use

# Execution Configuration
EXECUTION_TRIGGERS = ["merge"]  # Options: ["merge", "push", "pull_request"]
APPLY_RULE = "manual"  # Options: "manual", "auto"

# Workspace Variables (can be empty array if not needed)
WORKSPACE_VARIABLES = [
    # Example:
    # {
    #     "key": "ENV",
    #     "value": "production",
    #     "sensitivity": "string",  # Options: "string", "secret"
    #     "destination": "env"  # Options: "env", "iac"
    # }
]

# Optional Configuration
PROJECT_ID = None  # Project ID or None for global access (used when CREATE_PROJECTS is False)
CONSUMED_VARIABLE_SETS = []  # Array of variable set IDs

# Project Creation Configuration
CREATE_PROJECTS = True  # Set to True to create projects that mirror directory structure
# When CREATE_PROJECTS is True:
# - Creates a main project for each repository
# - Creates sub-projects for each directory level
# - Attaches workspaces to their corresponding sub-projects

# Project Members Configuration
# Users to attach to main projects (root project for each repository)
# Format: List of dictionaries with "userId" and "role" keys
# Role options: "admin", "member", "viewer" (check Firefly API documentation for available roles)
MAIN_PROJECT_MEMBERS = [
    # Example:
    # {
    #     "userId": "user-id-1",
    #     "role": "admin"
    # },
    # {
    #     "userId": "user-id-2",
    #     "role": "member"
    # }
]

# Users to attach to specific projects based on directory path
# Format: Dictionary mapping directory paths (work_dir format with leading slash) to lists of user dictionaries
# Example: "/aws/production" maps to the project created for that directory path
PROJECT_PATH_MEMBERS = {
    # Example:
    # "/aws/production": [
    #     {
    #         "userId": "user-id-1",
    #         "role": "admin"
    #     },
    #     {
    #         "userId": "user-id-2",
    #         "role": "member"
    #     }
    # ],
    # "/gcp/staging": [
    #     {
    #         "userId": "user-id-3",
    #         "role": "admin"
    #     }
    # ]
}

# Project Variables Configuration
# Variables to attach to main projects (root project for each repository)
# Format: List of variable dictionaries with "key", "value", "sensitivity", and "destination" keys
MAIN_PROJECT_VARIABLES = [
    # Example:
    # {
    #     "key": "ENV",
    #     "value": "production",
    #     "sensitivity": "string",  # Options: "string", "secret"
    #     "destination": "env"      # Options: "env", "iac"
    # },
    # {
    #     "key": "AWS_REGION",
    #     "value": "us-east-1",
    #     "sensitivity": "string",
    #     "destination": "env"
    # }
]

# Variables to attach to specific projects based on directory path
# Format: Dictionary mapping directory paths (work_dir format with leading slash) to lists of variable dictionaries
# Example: "/aws/production" maps to the project created for that directory path
PROJECT_PATH_VARIABLES = {
    # Example:
    # "/aws/production": [
    #     {
    #         "key": "ENV",
    #         "value": "production",
    #         "sensitivity": "string",
    #         "destination": "env"
    #     },
    #     {
    #         "key": "AWS_REGION",
    #         "value": "us-east-1",
    #         "sensitivity": "string",
    #         "destination": "env"
    #     }
    # ],
    # "/gcp/staging": [
    #     {
    #         "key": "ENV",
    #         "value": "staging",
    #         "sensitivity": "string",
    #         "destination": "env"
    #     }
    # ]
}

# Input/Output Files
MAPPING_JSON_FILE = "github_directory_mapping.json"  # Change to "test_github_directory_mapping.json" for testing
OUTPUT_LOG_FILE = "firefly_workflows_created.json"


# ============================================================================
# Helper Functions
# ============================================================================

def login_to_firefly() -> str:
    """
    Authenticate with Firefly API using access key and secret key.
    
    Returns:
        Access token string
    
    Raises:
        ValueError: If authentication fails
    """
    login_url = f"{FIREFLY_API_BASE_URL}/v2/login"
    
    headers = {
        "Content-Type": "application/json"
    }
    
    body = {
        "accessKey": ACCESS_KEY,
        "secretKey": SECRET_KEY
    }
    
    try:
        response = requests.post(login_url, data=json.dumps(body), headers=headers)
        response.raise_for_status()
        
        data = response.json()
        access_token = data.get("accessToken")
        
        if not access_token:
            raise ValueError("No accessToken received from login response")
        
        return access_token
    except requests.exceptions.RequestException as e:
        raise ValueError(f"Failed to authenticate with Firefly API: {e}")


def get_all_subdirectories(directory_structure: Dict[str, Any], base_path: str = "") -> List[str]:
    """
    Recursively extract only leaf directory paths (end directories with no subdirectories).
    
    Args:
        directory_structure: Nested dictionary representing directory structure
        base_path: Current base path (for recursion)
    
    Returns:
        List of only leaf directory paths (directories with no subdirectories)
    
    Example:
        Input: {
            "aws": {
                "something": {
                    "more": {
                        "nested": {"directories": {}},
                        "123": {}
                    }
                }
            }
        }
        Output: ["aws/something/more/nested/directories", "aws/something/more/123"]
    """
    paths = []
    
    for dir_name, subdirs in directory_structure.items():
        # Build the full path for this directory
        current_path = f"{base_path}/{dir_name}" if base_path else dir_name
        
        # If this directory has no subdirectories (is a leaf), add it
        if not subdirs or subdirs == {}:
            paths.append(current_path)
        else:
            # If this directory has subdirectories, recurse to find leaf directories
            paths.extend(get_all_subdirectories(subdirs, current_path))
    
    return paths


def create_firefly_workspace(
    repo: str,
    work_dir: str,
    workspace_name: str,
    access_token: str,
    description: str = None,
    project_id: str = None
) -> Dict[str, Any]:
    """
    Create a Firefly workspace using the Firefly API.
    
    Args:
        repo: Repository name in owner/repo format
        work_dir: Working directory path (subdirectory path with leading slash)
        workspace_name: Unique workspace name (full path format: owner/repo/subdir)
        access_token: Firefly API access token from login
        description: Optional workspace description
    
    Returns:
        API response dictionary
    """
    url = f"{FIREFLY_API_BASE_URL}/v2/runners/workspaces"
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    
    # Build request body according to Firefly API documentation
    request_body = {
        "runnerType": RUNNER_TYPE,
        "iacType": IAC_TYPE,
        "workspaceName": workspace_name,
        "vcsId": VCS_ID,
        "repo": repo,
        "defaultBranch": DEFAULT_BRANCH,
        "vcsType": VCS_TYPE,
        "workDir": work_dir,
        "variables": WORKSPACE_VARIABLES,
        "execution": {
            "triggers": EXECUTION_TRIGGERS,
            "applyRule": APPLY_RULE,
            "terraformVersion": TERRAFORM_VERSION
        }
    }
    
    # Add optional fields if provided
    if description:
        request_body["description"] = description
    
    # Handle project assignment
    # Only set project if we have a valid project_id, otherwise explicitly set to null
    if project_id is not None and project_id:
        request_body["project"] = project_id
    elif PROJECT_ID is not None and PROJECT_ID:
        request_body["project"] = PROJECT_ID
    else:
        # Explicitly set to null to avoid API trying to find a default project
        request_body["project"] = None
    
    if CONSUMED_VARIABLE_SETS:
        request_body["consumedVariableSets"] = CONSUMED_VARIABLE_SETS
    
    try:
        response = requests.post(url, json=request_body, headers=headers)
        response.raise_for_status()
        return {
            "success": True,
            "status_code": response.status_code,
            "data": response.json()
        }
    except requests.exceptions.RequestException as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": getattr(e.response, 'status_code', None) if hasattr(e, 'response') else None,
            "response_text": getattr(e.response, 'text', None) if hasattr(e, 'response') else None
        }


def generate_workspace_name(repo: str, work_dir: str) -> str:
    """
    Generate a unique workspace name from repository and work directory.
    Format: owner/repo/subdir (e.g., "Firefly-SE/lior/aws")
    
    Args:
        repo: Repository name in owner/repo format
        work_dir: Working directory path (e.g., "/aws" or "aws")
    
    Returns:
        Generated workspace name in format: owner/repo/subdir
    """
    # Remove leading slash from work_dir if present
    clean_work_dir = work_dir.lstrip('/')
    
    # Combine: owner/repo/subdir
    workspace_name = f"{repo}/{clean_work_dir}"
    
    return workspace_name


def sanitize_project_name(name: str) -> str:
    """
    Sanitize project name to meet Firefly API requirements.
    Project names must be 3-64 characters long, alphanumeric, and can contain hyphens and underscores.
    Cannot contain spaces or slashes.
    
    Args:
        name: Original project name (may contain spaces, slashes, etc.)
    
    Returns:
        Sanitized project name with hyphens replacing spaces and slashes
    """
    # Replace spaces and slashes with hyphens
    sanitized = name.replace(" ", "-").replace("/", "-")
    # Remove any double hyphens that might result
    while "--" in sanitized:
        sanitized = sanitized.replace("--", "-")
    # Remove leading/trailing hyphens
    sanitized = sanitized.strip("-")
    return sanitized


def format_work_dir(work_dir: str) -> str:
    """
    Format work directory path with leading slash.
    Format: /subdir (e.g., "/aws")
    
    Args:
        work_dir: Working directory path (e.g., "aws" or "/aws")
    
    Returns:
        Formatted work directory path with leading slash
    """
    # Ensure leading slash
    if not work_dir.startswith('/'):
        return f"/{work_dir}"
    return work_dir


def create_firefly_project(
    name: str,
    access_token: str,
    parent_id: str = None,
    description: str = None
) -> Dict[str, Any]:
    """
    Create a Firefly project using the Firefly API.
    
    Args:
        name: Project name
        access_token: Firefly API access token from login
        parent_id: Parent project ID (None for root projects)
        description: Optional project description
    
    Returns:
        API response dictionary with project ID
    """
    url = f"{FIREFLY_API_BASE_URL}/v2/runners/projects"
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    
    request_body = {
        "name": name
    }
    
    if parent_id:
        request_body["parentId"] = parent_id
    
    if description:
        request_body["description"] = description
    
    try:
        # Use data=json.dumps() to match API documentation format
        response = requests.post(url, data=json.dumps(request_body), headers=headers)
        response.raise_for_status()
        return {
            "success": True,
            "status_code": response.status_code,
            "data": response.json(),
            "project_id": response.json().get("id")
        }
    except requests.exceptions.RequestException as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": getattr(e.response, 'status_code', None) if hasattr(e, 'response') else None,
            "response_text": getattr(e.response, 'text', None) if hasattr(e, 'response') else None,
            "project_id": None
        }


def add_project_members(
    project_id: str,
    members: List[Dict[str, str]],
    access_token: str
) -> Dict[str, Any]:
    """
    Add members to a Firefly project.
    
    Args:
        project_id: Project ID to add members to
        members: List of member dictionaries with "userId" and "role" keys
        access_token: Firefly API access token from login
    
    Returns:
        API response dictionary
    """
    url = f"{FIREFLY_API_BASE_URL}/v2/runners/projects/{project_id}/members"
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    
    try:
        response = requests.post(url, data=json.dumps(members), headers=headers)
        response.raise_for_status()
        return {
            "success": True,
            "status_code": response.status_code,
            "data": response.json() if response.content else None
        }
    except requests.exceptions.RequestException as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": getattr(e.response, 'status_code', None) if hasattr(e, 'response') else None,
            "response_text": getattr(e.response, 'text', None) if hasattr(e, 'response') else None
        }


def add_project_variables(
    project_id: str,
    variables: List[Dict[str, str]],
    access_token: str
) -> Dict[str, Any]:
    """
    Add variables to a Firefly project.
    
    Args:
        project_id: Project ID to add variables to
        variables: List of variable dictionaries with "key", "value", "sensitivity", and "destination" keys
        access_token: Firefly API access token from login
    
    Returns:
        API response dictionary
    """
    url = f"{FIREFLY_API_BASE_URL}/v2/runners/variables/projects/{project_id}/variables"
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    
    request_body = {
        "variables": variables
    }
    
    try:
        response = requests.post(url, data=json.dumps(request_body), headers=headers)
        response.raise_for_status()
        return {
            "success": True,
            "status_code": response.status_code,
            "data": response.json() if response.content else None
        }
    except requests.exceptions.RequestException as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": getattr(e.response, 'status_code', None) if hasattr(e, 'response') else None,
            "response_text": getattr(e.response, 'text', None) if hasattr(e, 'response') else None
        }


def build_project_tree(
    directory_structure: Dict[str, Any],
    repo: str,
    base_path: str = "",
    parent_project_id: str = None,
    access_token: str = None,
    project_map: Dict[str, str] = None,
    existing_projects_tree: Dict[str, Any] = None
) -> Dict[str, str]:
    """
    Recursively build project tree from directory structure.
    Creates projects for each directory level and maps work directories to project IDs.
    Uses tree endpoint to check for existing projects before creating new ones.
    
    Args:
        directory_structure: Nested dictionary representing directory structure
        repo: Repository name in owner/repo format
        base_path: Current base path (for recursion)
        parent_project_id: Parent project ID (None for root)
        access_token: Firefly API access token
        project_map: Dictionary mapping work_dir paths to project IDs
        existing_projects_tree: Existing projects tree data from API
    
    Returns:
        Dictionary mapping work_dir paths to project IDs
    """
    if project_map is None:
        project_map = {}
    
    for dir_name, subdirs in directory_structure.items():
        # Build the full path for this directory
        current_path = f"{base_path}/{dir_name}" if base_path else dir_name
        formatted_path = format_work_dir(current_path)
        
        # Generate project name: repo/dir or repo/path/to/dir
        # Sanitize to replace spaces with hyphens
        project_name = sanitize_project_name(generate_workspace_name(repo, current_path))
        project_description = f"Project for {repo}{formatted_path}"
        
        # Check if project already exists in tree
        existing_project = None
        if existing_projects_tree:
            existing_project = find_project_by_name(existing_projects_tree, project_name)
        
        if existing_project:
            # Project already exists, use its ID
            project_id = existing_project.get("id")
            project_map[formatted_path] = project_id
            print(f"    Found existing project: {project_name} (ID: {project_id})")
        else:
            # Create new project
            print(f"    Creating project: {project_name}")
            if parent_project_id:
                print(f"      Parent: {parent_project_id}")
            
            result = create_firefly_project(
                name=project_name,
                access_token=access_token,
                parent_id=parent_project_id,
                description=project_description
            )
            
            if result["success"]:
                project_id = result["project_id"]
                project_map[formatted_path] = project_id
                print(f"      ✓ Created project with ID: {project_id}")
            else:
                error_msg = result.get('error', 'Unknown error')
                print(f"      ✗ Failed to create project: {error_msg}")
                if result.get("response_text"):
                    print(f"        Response: {result['response_text']}")
                # Continue with children even if parent fails (they'll use None as parent)
                project_id = None
                # Don't add to project_map if creation failed
        
        # Recursively create sub-projects
        # Note: We create projects for ALL directory levels, including leaf directories
        # This ensures that workspaces (which are created for leaf directories) can be matched
        if subdirs and project_id:
            build_project_tree(
                subdirs,
                repo,
                current_path,
                project_id,
                access_token,
                project_map,
                existing_projects_tree
            )
        # If this is a leaf directory (no subdirs), the project for this path is already created above
        # and added to project_map, so workspaces for this path will match correctly
    
    return project_map


def get_projects_tree(access_token: str, search_query: Optional[str] = None) -> Dict[str, Any]:
    """
    Get all projects in tree structure using /v2/runners/projects/tree.
    
    Args:
        access_token: Firefly API access token
        search_query: Optional search query to filter projects
    
    Returns:
        API response dictionary with tree data
    """
    url = f"{FIREFLY_API_BASE_URL}/v2/runners/projects/tree"
    
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Accept": "*/*"
    }
    
    params = {}
    if search_query:
        params["searchQuery"] = search_query
    
    try:
        response = requests.get(url, headers=headers, params=params)
        response.raise_for_status()
        return {
            "success": True,
            "status_code": response.status_code,
            "data": response.json()
        }
    except requests.exceptions.RequestException as e:
        return {
            "success": False,
            "error": str(e),
            "status_code": getattr(e.response, 'status_code', None) if hasattr(e, 'response') else None,
            "response_text": getattr(e.response, 'text', None) if hasattr(e, 'response') else None
        }


def find_root_projects(tree_data: Dict[str, Any]) -> List[Dict[str, Any]]:
    """
    Find all root projects (projects with no parentId) from tree structure.
    
    Args:
        tree_data: Response from /v2/runners/projects/tree endpoint
        
    Returns:
        List of root project objects
    """
    root_projects = []
    
    def traverse(data_list: List[Dict[str, Any]]):
        """Recursively traverse the tree structure."""
        for item in data_list:
            # Check if this is a project object (has 'id' field)
            if "id" in item:
                # If no parentId, it's a root project
                if not item.get("parentId"):
                    root_projects.append(item)
            
            # If item has children, traverse them
            if "children" in item:
                traverse(item["children"])
            
            # If item has a 'data' field (nested structure), traverse it
            if "data" in item and isinstance(item["data"], list):
                traverse(item["data"])
    
    # Start traversal from the top-level data array
    if "data" in tree_data:
        traverse(tree_data["data"])
    
    return root_projects


def find_project_by_name(tree_data: Dict[str, Any], project_name: str) -> Optional[Dict[str, Any]]:
    """
    Find a project by name in the tree structure.
    
    Args:
        tree_data: Response from /v2/runners/projects/tree endpoint
        project_name: Name of the project to find
        
    Returns:
        Project object if found, None otherwise
    """
    def traverse(data_list: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        """Recursively traverse the tree structure."""
        for item in data_list:
            # Check if this is a project object (has 'id' and 'name' fields)
            if "id" in item and "name" in item:
                if item.get("name") == project_name:
                    return item
            
            # If item has children, traverse them
            if "children" in item:
                result = traverse(item["children"])
                if result:
                    return result
            
            # If item has a 'data' field (nested structure), traverse it
            if "data" in item and isinstance(item["data"], list):
                result = traverse(item["data"])
                if result:
                    return result
        
        return None
    
    # Start traversal from the top-level data array
    if "data" in tree_data:
        return traverse(tree_data["data"])
    
    return None


def get_project_id_for_work_dir(work_dir: str, project_map: Dict[str, str]) -> Optional[str]:
    """
    Get the project ID for a given work directory path.
    Finds the exact matching project for the workspace's work directory.
    Workspaces should be attached to the project that matches their exact work directory path.
    
    Args:
        work_dir: Work directory path (e.g., "/aws/production")
        project_map: Dictionary mapping work_dir paths to project IDs
    
    Returns:
        Project ID or None if not found
    """
    # Normalize the work_dir to ensure consistent format
    normalized_work_dir = format_work_dir(work_dir.lstrip('/'))
    
    # Try exact match first (most common case - workspace matches leaf project)
    if normalized_work_dir in project_map:
        return project_map[normalized_work_dir]
    
    # Also try the work_dir as-is (in case it's already formatted)
    if work_dir in project_map:
        return project_map[work_dir]
    
    # If no exact match, try to find the most specific parent project
    # This handles cases where a project might not exist for the exact leaf directory
    best_match = None
    best_match_length = 0
    
    for path, project_id in project_map.items():
        # Check if work_dir starts with path (work_dir is a subdirectory of this project)
        if normalized_work_dir.startswith(path) and len(path) > best_match_length:
            best_match = project_id
            best_match_length = len(path)
    
    return best_match


# ============================================================================
# Main Function
# ============================================================================

def main():
    """Main function to process GitHub mapping and create Firefly workflows."""
    
    # Validate configuration
    if ACCESS_KEY == "YOUR_ACCESS_KEY":
        print("ERROR: Please set ACCESS_KEY in the script!")
        return 1
    
    if SECRET_KEY == "YOUR_SECRET_KEY":
        print("ERROR: Please set SECRET_KEY in the script!")
        return 1
    
    if VCS_ID == "YOUR_VCS_INTEGRATION_ID":
        print("ERROR: Please set VCS_ID in the script!")
        return 1
    
    # Authenticate with Firefly API
    print("Authenticating with Firefly API...")
    try:
        access_token = login_to_firefly()
        print("✓ Authentication successful")
    except ValueError as e:
        print(f"ERROR: {e}")
        return 1
    
    # Load GitHub directory mapping
    try:
        with open(MAPPING_JSON_FILE, 'r', encoding='utf-8') as f:
            mapping_data = json.load(f)
    except FileNotFoundError:
        print(f"ERROR: Mapping file '{MAPPING_JSON_FILE}' not found!")
        print("Please run get_github_mapping.py first to generate the mapping.")
        return 1
    except json.JSONDecodeError as e:
        print(f"ERROR: Invalid JSON in '{MAPPING_JSON_FILE}': {e}")
        return 1
    
    print("="*70)
    print("Creating Firefly Workflows from GitHub Directory Mapping")
    print("="*70)
    print(f"\nConfiguration:")
    print(f"  API Base URL: {FIREFLY_API_BASE_URL}")
    print(f"  VCS Type: {VCS_TYPE}")
    print(f"  Runner Type: {RUNNER_TYPE}")
    print(f"  IAC Type: {IAC_TYPE}")
    print(f"  Terraform Version: {TERRAFORM_VERSION}")
    print(f"  Default Branch: {DEFAULT_BRANCH}")
    print(f"  Apply Rule: {APPLY_RULE}")
    print(f"  Triggers: {', '.join(EXECUTION_TRIGGERS)}")
    print(f"  Create Projects: {CREATE_PROJECTS}")
    print()
    
    # Process each repository
    results = {
        "total_repos": len(mapping_data),
        "total_workflows_created": 0,
        "total_workflows_failed": 0,
        "total_projects_created": 0,
        "total_projects_failed": 0,
        "workflows": [],
        "projects": []
    }
    
    for repo, directory_structure in mapping_data.items():
        print(f"\n{'='*70}")
        print(f"Processing Repository: {repo}")
        print(f"{'='*70}")
        
        # Create project tree if enabled
        project_map = {}
        root_project_id = None
        if CREATE_PROJECTS:
            print(f"\n  Creating project structure for {repo}...")
            
            # Get existing projects tree to check for existing projects
            print("    Retrieving existing projects tree...")
            tree_result = get_projects_tree(access_token)
            existing_projects_tree = None
            existing_root_project_id = None
            
            if tree_result["success"]:
                existing_projects_tree = tree_result["data"]
                print("      ✓ Retrieved existing projects tree")
                
                # Find root project (projects with no parentId)
                root_projects = find_root_projects(existing_projects_tree)
                if root_projects:
                    existing_root = root_projects[0]
                    existing_root_project_id = existing_root.get("id")
                    existing_root_name = existing_root.get("name", "Unknown")
                    print(f"      Found existing root project: {existing_root_name} (ID: {existing_root_project_id})")
            else:
                print(f"      ⚠ Could not retrieve projects tree: {tree_result.get('error', 'Unknown error')}")
            
            # Create main project for the repository
            # Sanitize repo name (replace spaces with hyphens)
            repo_project_name = sanitize_project_name(repo)
            repo_project_description = f"Main project for {repo}"
            
            # Check if main project already exists
            existing_main_project = None
            main_project_created = 0
            if existing_projects_tree:
                existing_main_project = find_project_by_name(existing_projects_tree, repo_project_name)
            
            if existing_main_project:
                root_project_id = existing_main_project.get("id")
                print(f"    Found existing main project: {repo_project_name} (ID: {root_project_id})")
            else:
                print(f"    Creating main project: {repo_project_name}")
                # Use existing root project as parent if available, otherwise None (will create as root)
                repo_project_result = create_firefly_project(
                    name=repo_project_name,
                    access_token=access_token,
                    parent_id=existing_root_project_id,  # Use existing root as parent, or None for new root
                    description=repo_project_description
                )
                
                if repo_project_result["success"]:
                    root_project_id = repo_project_result["project_id"]
                    print(f"      ✓ Created main project with ID: {root_project_id}")
                    main_project_created = 1
                    results["total_projects_created"] += 1
                    
                    # Add members to main project if configured
                    if MAIN_PROJECT_MEMBERS:
                        print(f"    Adding members to main project...")
                        members_result = add_project_members(
                            project_id=root_project_id,
                            members=MAIN_PROJECT_MEMBERS,
                            access_token=access_token
                        )
                        if members_result["success"]:
                            print(f"      ✓ Added {len(MAIN_PROJECT_MEMBERS)} member(s) to main project")
                        else:
                            print(f"      ✗ Failed to add members: {members_result.get('error', 'Unknown error')}")
                    
                    # Add variables to main project if configured
                    if MAIN_PROJECT_VARIABLES:
                        print(f"    Adding variables to main project...")
                        variables_result = add_project_variables(
                            project_id=root_project_id,
                            variables=MAIN_PROJECT_VARIABLES,
                            access_token=access_token
                        )
                        if variables_result["success"]:
                            print(f"      ✓ Added {len(MAIN_PROJECT_VARIABLES)} variable(s) to main project")
                        else:
                            print(f"      ✗ Failed to add variables: {variables_result.get('error', 'Unknown error')}")
            
            # Add members to existing main project if configured
            if existing_main_project and MAIN_PROJECT_MEMBERS:
                print(f"    Adding members to existing main project...")
                members_result = add_project_members(
                    project_id=root_project_id,
                    members=MAIN_PROJECT_MEMBERS,
                    access_token=access_token
                )
                if members_result["success"]:
                    print(f"      ✓ Added {len(MAIN_PROJECT_MEMBERS)} member(s) to main project")
                else:
                    print(f"      ✗ Failed to add members: {members_result.get('error', 'Unknown error')}")
            
            # Add variables to existing main project if configured
            if existing_main_project and MAIN_PROJECT_VARIABLES:
                print(f"    Adding variables to existing main project...")
                variables_result = add_project_variables(
                    project_id=root_project_id,
                    variables=MAIN_PROJECT_VARIABLES,
                    access_token=access_token
                )
                if variables_result["success"]:
                    print(f"      ✓ Added {len(MAIN_PROJECT_VARIABLES)} variable(s) to main project")
                else:
                    print(f"      ✗ Failed to add variables: {variables_result.get('error', 'Unknown error')}")
            else:
                if not existing_main_project:
                    error_msg = repo_project_result.get('error', 'Unknown error')
                    print(f"      ✗ Failed to create main project: {error_msg}")
                    if repo_project_result.get("response_text"):
                        print(f"        Response: {repo_project_result['response_text']}")
                    # If creation failed but we have an existing root, use that
                    if existing_root_project_id:
                        root_project_id = existing_root_project_id
                        print(f"      Using existing root project: {existing_root_project_id}")
            
            # Create sub-projects under the main project
            project_map = build_project_tree(
                directory_structure,
                repo,
                base_path="",
                parent_project_id=root_project_id,
                access_token=access_token,
                project_map={},
                existing_projects_tree=existing_projects_tree
            )
            
            # Count created projects
            # Note: project_map contains all projects (existing + newly created)
            # We need to check which ones were newly created by comparing with existing tree
            # For simplicity, we'll count all projects in project_map as created
            # (The build_project_tree function already handles checking for existing projects)
            created_sub_projects = len(project_map)
            total_projects = created_sub_projects + main_project_created
            results["total_projects_created"] += created_sub_projects
            if total_projects > 0:
                print(f"\n  ✓ Processed {total_projects} projects for {repo} ({main_project_created} main + {created_sub_projects} sub-projects)")
            else:
                print(f"\n  ✓ All projects already exist for {repo}")
            
            # Add members to specific projects based on path
            if PROJECT_PATH_MEMBERS:
                print(f"\n  Adding members to specific projects based on path...")
                for path, members in PROJECT_PATH_MEMBERS.items():
                    # Normalize path to match format_work_dir format
                    normalized_path = format_work_dir(path.lstrip('/'))
                    
                    # Check if this path exists in project_map
                    project_id = None
                    if normalized_path in project_map:
                        project_id = project_map[normalized_path]
                    elif path in project_map:
                        project_id = project_map[path]
                    
                    if project_id:
                        print(f"    Adding {len(members)} member(s) to project at path: {normalized_path}")
                        members_result = add_project_members(
                            project_id=project_id,
                            members=members,
                            access_token=access_token
                        )
                        if members_result["success"]:
                            print(f"      ✓ Added members to project {project_id}")
                        else:
                            print(f"      ✗ Failed to add members: {members_result.get('error', 'Unknown error')}")
                    else:
                        print(f"    ⚠ Warning: No project found for path '{normalized_path}' (path not in project_map)")
            
            # Add variables to specific projects based on path
            if PROJECT_PATH_VARIABLES:
                print(f"\n  Adding variables to specific projects based on path...")
                for path, variables in PROJECT_PATH_VARIABLES.items():
                    # Normalize path to match format_work_dir format
                    normalized_path = format_work_dir(path.lstrip('/'))
                    
                    # Check if this path exists in project_map
                    project_id = None
                    if normalized_path in project_map:
                        project_id = project_map[normalized_path]
                    elif path in project_map:
                        project_id = project_map[path]
                    
                    if project_id:
                        print(f"    Adding {len(variables)} variable(s) to project at path: {normalized_path}")
                        variables_result = add_project_variables(
                            project_id=project_id,
                            variables=variables,
                            access_token=access_token
                        )
                        if variables_result["success"]:
                            print(f"      ✓ Added variables to project {project_id}")
                        else:
                            print(f"      ✗ Failed to add variables: {variables_result.get('error', 'Unknown error')}")
                    else:
                        print(f"    ⚠ Warning: No project found for path '{normalized_path}' (path not in project_map)")
        
        # Get all subdirectories for this repo
        subdirectories = get_all_subdirectories(directory_structure)
        
        if not subdirectories:
            print(f"  No subdirectories found in {repo}")
            continue
        
        print(f"  Found {len(subdirectories)} subdirectories")
        
        # Create workflow for each subdirectory
        for work_dir in subdirectories:
            # Format work directory with leading slash
            formatted_work_dir = format_work_dir(work_dir)
            
            # Generate workspace name: owner/repo/subdir
            workspace_name = generate_workspace_name(repo, work_dir)
            description = f"Workflow for {repo}{formatted_work_dir}"
            
            print(f"\n  Creating workspace: {workspace_name}")
            print(f"    Repository: {repo}")
            print(f"    Work Directory: {formatted_work_dir}")
            
            # Get project ID for this workspace if projects are enabled
            # The workspace should be attached to the project that matches its work directory path
            workspace_project_id = None
            if CREATE_PROJECTS:
                workspace_project_id = get_project_id_for_work_dir(formatted_work_dir, project_map)
                if workspace_project_id:
                    print(f"    Project ID: {workspace_project_id} (matched to work_dir: {formatted_work_dir})")
                else:
                    print(f"    Warning: No project ID found for {formatted_work_dir}")
                    print(f"      Available projects in map: {list(project_map.keys())[:5]}...")  # Show first 5 for debugging
                    print(f"      Creating workspace without project")
            
            # Create the workspace
            result = create_firefly_workspace(
                repo=repo,
                work_dir=formatted_work_dir,
                workspace_name=workspace_name,
                access_token=access_token,
                description=description,
                project_id=workspace_project_id
            )
            
            workflow_info = {
                "repo": repo,
                "work_dir": formatted_work_dir,
                "workspace_name": workspace_name,
                "description": description,
                "success": result["success"]
            }
            
            if CREATE_PROJECTS and workspace_project_id:
                workflow_info["project_id"] = workspace_project_id
            
            if result["success"]:
                print(f"    ✓ Successfully created workspace")
                workflow_info["workspace_id"] = result["data"].get("id")
                workflow_info["status_code"] = result["status_code"]
                results["total_workflows_created"] += 1
            else:
                print(f"    ✗ Failed to create workspace")
                print(f"      Error: {result.get('error', 'Unknown error')}")
                if result.get("status_code"):
                    print(f"      Status Code: {result['status_code']}")
                if result.get("response_text"):
                    print(f"      Response: {result['response_text'][:200]}")
                workflow_info["error"] = result.get("error")
                workflow_info["status_code"] = result.get("status_code")
                results["total_workflows_failed"] += 1
            
            results["workflows"].append(workflow_info)
        
        # Store project mapping for this repo
        if CREATE_PROJECTS:
            project_info = {
                "repo": repo,
                "root_project_id": root_project_id,
                "project_map": project_map
            }
            results["projects"].append(project_info)
    
    # Save results to file
    try:
        with open(OUTPUT_LOG_FILE, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"\n{'='*70}")
        print("Summary")
        print(f"{'='*70}")
        print(f"Total repositories processed: {results['total_repos']}")
        print(f"Total workflows created: {results['total_workflows_created']}")
        print(f"Total workflows failed: {results['total_workflows_failed']}")
        if CREATE_PROJECTS:
            print(f"Total projects created: {results['total_projects_created']}")
        print(f"\nResults saved to: {OUTPUT_LOG_FILE}")
    except Exception as e:
        print(f"\nWarning: Could not save results to file: {e}")
    
    return 0 if results["total_workflows_failed"] == 0 else 1


if __name__ == '__main__':
    exit(main())