#!/usr/bin/env python3
"""
Script to create a mapping of directories from a GitHub repository that contain .tf files.
Only includes directories that have .tf files (directly or in subdirectories),
and all parent directories leading to those directories.
Leaf directories without .tf files are excluded.
The mapping can be output as a nested dictionary structure or saved to a JSON file.
"""

import os
import json
import sys
from typing import Dict, Any, Optional, Tuple
from urllib.parse import urlparse
import requests

# Hardcoded GitHub token (replace with your actual token)
GITHUB_TOKEN = "GITHUB_TOKEN"

# Hardcoded repositories to map (replace with your repositories)
REPOS_TO_MAP = [
#    "REPOS_TO_MAP_EXAMPLE_1",
]

def parse_repo_input(repo_input: str) -> Tuple[str, Optional[str], bool]:
    """
    Parse repository/organization input to extract owner and optionally repo name.
    
    Supports:
    - owner/repo (individual repository)
    - owner (organization - will map all repos)
    - https://github.com/owner/repo (individual repository)
    - https://github.com/owner (organization - will map all repos)
    
    Args:
        repo_input: Repository or organization identifier
    
    Returns:
        Tuple of (owner, repo, is_org) where repo is None if it's an organization
    """
    # Handle GitHub URL
    if repo_input.startswith('http'):
        parsed = urlparse(repo_input)
        path_parts = parsed.path.strip('/').split('/')
        if len(path_parts) >= 2:
            owner = path_parts[0]
            repo = path_parts[1].replace('.git', '')
            return owner, repo, False
        elif len(path_parts) == 1:
            owner = path_parts[0]
            return owner, None, True
    
    # Handle owner/repo format
    if '/' in repo_input:
        parts = repo_input.split('/')
        if len(parts) == 2:
            return parts[0], parts[1], False
        elif len(parts) == 1:
            return parts[0], None, True
    
    # Handle just owner (organization)
    return repo_input, None, True


def get_organization_repos(org: str, token: Optional[str] = None) -> list:
    """
    Get all repositories for an organization.
    
    Args:
        org: Organization name
        token: GitHub personal access token
    
    Returns:
        List of repository names (owner/repo format)
    """
    base_url = "https://api.github.com"
    headers = {
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "GitHub-Directory-Mapper"
    }
    
    if token:
        headers["Authorization"] = f"token {token}"
    
    repos = []
    page = 1
    per_page = 100
    
    while True:
        org_url = f"{base_url}/orgs/{org}/repos?page={page}&per_page={per_page}&type=all"
        try:
            response = requests.get(org_url, headers=headers)
            response.raise_for_status()
            repo_list = response.json()
            
            if not repo_list:
                break
            
            for repo_data in repo_list:
                repos.append(f"{repo_data['owner']['login']}/{repo_data['name']}")
            
            # If we got fewer than per_page, we're done
            if len(repo_list) < per_page:
                break
            
            page += 1
        except requests.exceptions.RequestException as e:
            raise ValueError(f"Failed to fetch organization repos: {e}")
    
    return repos


def get_github_token() -> Optional[str]:
    """
    Get GitHub token from hardcoded value, environment variable, or return None.
    
    Returns:
        GitHub token or None if not set
    """
    # First check hardcoded token (if not placeholder)
    if GITHUB_TOKEN and GITHUB_TOKEN != "GITHUB_TOKEN":
        return GITHUB_TOKEN
    # Fall back to environment variables
    return os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')


def create_directory_mapping(owner: str, repo: str, token: Optional[str] = None, branch: Optional[str] = None) -> Dict[str, Any]:
    """
    Create a nested dictionary mapping of directories that contain .tf files.
    Only includes directories that have .tf files (directly or in subdirectories),
    and all parent directories leading to those directories.
    
    Args:
        owner: Repository owner/username
        repo: Repository name
        token: GitHub personal access token (optional, for private repos or higher rate limits)
        branch: Branch name (default: default branch)
    
    Returns:
        A nested dictionary representing the directory structure (only directories with .tf files)
    """
    base_url = "https://api.github.com"
    headers = {
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "GitHub-Directory-Mapper"
    }
    
    if token:
        headers["Authorization"] = f"token {token}"
    
    # Get default branch if not specified
    if not branch:
        repo_url = f"{base_url}/repos/{owner}/{repo}"
        try:
            response = requests.get(repo_url, headers=headers)
            response.raise_for_status()
            repo_data = response.json()
            branch = repo_data.get("default_branch", "main")
        except requests.exceptions.RequestException as e:
            raise ValueError(f"Failed to fetch repository info: {e}")
    
    # Get the tree SHA for the branch
    ref_url = f"{base_url}/repos/{owner}/{repo}/git/ref/heads/{branch}"
    try:
        response = requests.get(ref_url, headers=headers)
        if response.status_code == 404:
            raise ValueError(f"Branch '{branch}' not found. Repository may not exist or you may not have access.")
        response.raise_for_status()
        ref_data = response.json()
        tree_sha = ref_data["object"]["sha"]
    except requests.exceptions.RequestException as e:
        raise ValueError(f"Failed to fetch branch reference: {e}")
    
    # Get recursive tree (all files and directories)
    tree_url = f"{base_url}/repos/{owner}/{repo}/git/trees/{tree_sha}?recursive=1"
    try:
        response = requests.get(tree_url, headers=headers)
        response.raise_for_status()
        tree_data = response.json()
    except requests.exceptions.RequestException as e:
        raise ValueError(f"Failed to fetch repository tree: {e}")
    
    # Find all .tf files and collect their directory paths
    all_items = tree_data.get("tree", [])
    tf_files = [item for item in all_items if item.get("type") == "blob" and item.get("path", "").endswith(".tf")]
    
    # Build a set of directories that should be included
    # This includes directories containing .tf files and all their parent directories
    directories_to_include = set()
    
    for tf_file in tf_files:
        file_path = tf_file.get("path", "")
        # Skip hidden files
        if file_path.startswith('.'):
            continue
        
        # Get the directory path (remove filename)
        if '/' in file_path:
            dir_path = '/'.join(file_path.split('/')[:-1])
        else:
            # File is in root directory
            dir_path = ""
        
        # Add this directory and all parent directories
        if dir_path:
            # Add all parent paths
            parts = dir_path.split('/')
            for i in range(len(parts)):
                parent_path = '/'.join(parts[:i+1])
                directories_to_include.add(parent_path)
        # If file is in root, we don't need to add anything (root is implicit)
    
    # Build nested dictionary structure from included directories
    mapping = {}
    
    for dir_path in sorted(directories_to_include):
        # Skip hidden directories
        if dir_path.startswith('.'):
            continue
        
        # Split path into parts
        parts = dir_path.split('/')
        
        # Navigate/create nested structure
        current = mapping
        for part in parts:
            if part not in current:
                current[part] = {}
            current = current[part]
    
    return mapping


def print_mapping(mapping: Dict[str, Any], indent: int = 0) -> None:
    """
    Pretty print the directory mapping.
    
    Args:
        mapping: The directory mapping dictionary
        indent: Current indentation level for pretty printing
    """
    for key, value in mapping.items():
        prefix = "  " * indent + "├── " if indent > 0 else ""
        print(f"{prefix}{key}")
        if isinstance(value, dict) and value:
            print_mapping(value, indent + 1)


def save_mapping_to_json(mapping: Dict[str, Any], output_file: str) -> None:
    """
    Save the directory mapping to a JSON file.
    
    Args:
        mapping: The directory mapping dictionary
        output_file: Path to the output JSON file
    """
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(mapping, f, indent=2, ensure_ascii=False)
    print(f"\nMapping saved to: {output_file}")


def main():
    """Main function to run the directory mapping script."""
    try:
        # Get token from hardcoded value or environment
        token = get_github_token()
        
        if not token:
            print("Warning: No GitHub token provided. Using unauthenticated requests (limited to 60 requests/hour).")
            print("For private repos or higher rate limits, set GITHUB_TOKEN in the code or environment variable.")
        
        # Process all hardcoded repos/organizations
        all_mappings = {}
        
        for repo_input in REPOS_TO_MAP:
            owner, repo, is_org = parse_repo_input(repo_input)
            
            if is_org:
                # Map entire organization
                print(f"\n{'='*60}")
                print(f"Processing organization: {owner}")
                print(f"{'='*60}")
                
                try:
                    org_repos = get_organization_repos(owner, token=token)
                    print(f"Found {len(org_repos)} repositories in organization")
                    
                    for repo_name in org_repos:
                        repo_owner, repo_name_only = repo_name.split('/')
                        print(f"\nFetching directory mapping for: {repo_name}")
                        
                        try:
                            repo_mapping = create_directory_mapping(
                                repo_owner, 
                                repo_name_only, 
                                token=token
                            )
                            all_mappings[repo_name] = repo_mapping
                            
                            # Count directories for this repo
                            def count_directories(m: Dict[str, Any]) -> int:
                                count = 0
                                for value in m.values():
                                    if isinstance(value, dict):
                                        count += 1
                                        if any(isinstance(v, dict) for v in value.values()):
                                            count += count_directories(value)
                                return count
                            
                            total_dirs = count_directories(repo_mapping)
                            print(f"  ✓ Mapped {total_dirs} directories")
                        except Exception as e:
                            print(f"  ✗ Error mapping {repo_name}: {e}")
                            all_mappings[repo_name] = {"error": str(e)}
                
                except Exception as e:
                    print(f"Error processing organization {owner}: {e}")
                    all_mappings[f"{owner}/*"] = {"error": str(e)}
            
            else:
                # Map individual repository
                print(f"\n{'='*60}")
                print(f"Fetching directory mapping for: {owner}/{repo}")
                print(f"{'='*60}")
                
                try:
                    repo_mapping = create_directory_mapping(owner, repo, token=token)
                    all_mappings[f"{owner}/{repo}"] = repo_mapping
                    
                    # Count directories
                    def count_directories(m: Dict[str, Any]) -> int:
                        count = 0
                        for value in m.values():
                            if isinstance(value, dict):
                                count += 1
                                if any(isinstance(v, dict) for v in value.values()):
                                    count += count_directories(value)
                        return count
                    
                    total_dirs = count_directories(repo_mapping)
                    print(f"Total directories mapped: {total_dirs}")
                
                except Exception as e:
                    print(f"Error mapping {owner}/{repo}: {e}")
                    all_mappings[f"{owner}/{repo}"] = {"error": str(e)}
        
        # Save all mappings to JSON file
        output_file = "github_directory_mapping.json"
        save_mapping_to_json(all_mappings, output_file)
        
        # Print summary
        print(f"\n{'='*60}")
        print("Summary:")
        print(f"{'='*60}")
        print(f"Total repositories/organizations processed: {len(REPOS_TO_MAP)}")
        print(f"Total mappings saved: {len(all_mappings)}")
        print(f"Output file: {output_file}")
        
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1
    
    return 0


if __name__ == '__main__':
    exit(main())