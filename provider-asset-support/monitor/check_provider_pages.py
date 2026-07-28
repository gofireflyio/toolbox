#!/usr/bin/env python3
"""
Sync Firefly's "Supported Provider Resources" from Confluence into this repo.

Source of truth (Sales Engineering Knowledge Hub, space SEKH):
  - AWS   Provider  -> flywheel-provider-aws    (page 531169307)
  - Azure Provider  -> flywheel-provider-azure   (page 531169349)
  - GCP   Provider  -> flywheel-provider-gcp      (page 531169328)

Each page is a flat list of supported Terraform resource types. Run by the
biweekly GitHub Action, this script:

  1. Fetches the live supported-type list for each provider from Confluence.
  2. Rewrites the machine-readable lists (supported-types/<provider>.txt) and
     the structured baseline (monitor/providers.baseline.json). Output is
     deterministic (sorted, no timestamps) so `git` is the source of truth for
     "did anything change".
  3. Writes monitor/report.md describing what changed since the committed
     baseline, plus a checklist of which asset-count scripts / PDFs need a
     human follow-up (new supported types that are not yet mapped in a script
     cannot be auto-added, because the mapping needs the cloud-native inventory
     type, which the Confluence list does not provide).

The workflow then opens a PR if any tracked file changed.

Dependency-free (Python 3 standard library only) so it runs on a bare runner.

Auth: env vars
  CONFLUENCE_EMAIL      Atlassian account email
  CONFLUENCE_API_TOKEN  Atlassian API token (id.atlassian.com)
  CONFLUENCE_BASE_URL   optional, defaults to https://infralight1.atlassian.net
"""

import base64
import json
import os
import re
import sys
import urllib.request
import urllib.error

BASE_URL = os.environ.get("CONFLUENCE_BASE_URL", "https://infralight1.atlassian.net").rstrip("/")

# Provider key -> Confluence page + the asset-count script that implements it.
PROVIDERS = {
    "aws":   {"page_id": "531169307", "label": "AWS",   "title": "AWS Provider",
              "script": "scripts/firefly_aws_asset_count.sh"},
    "azure": {"page_id": "531169349", "label": "Azure", "title": "Azure Provider",
              "script": "scripts/firefly_azure_asset_count.sh"},
    "gcp":   {"page_id": "531169328", "label": "GCP",   "title": "Google Cloud Provider",
              "script": "scripts/firefly_gcp_asset_count.sh"},
}

MONITOR_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(MONITOR_DIR)                       # provider-asset-support/
BASELINE_PATH = os.path.join(MONITOR_DIR, "providers.baseline.json")
LISTS_DIR = os.path.join(ROOT, "supported-types")
REPORT_PATH = os.path.join(MONITOR_DIR, "report.md")

# A supported resource type looks like aws_*, azurerm_*, or google_*.
TYPE_RE = re.compile(r"^(?:aws|azurerm|google)_[a-z0-9_]+$")
# Terraform types referenced on the right-hand side of a script's MAP.
SCRIPT_MAP_RE = re.compile(r'"((?:aws|azurerm|google)_[a-z0-9_]+)"')


def _auth_header():
    email = os.environ.get("CONFLUENCE_EMAIL")
    token = os.environ.get("CONFLUENCE_API_TOKEN")
    if not email or not token:
        sys.exit("ERROR: CONFLUENCE_EMAIL and CONFLUENCE_API_TOKEN must be set.")
    return "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode("ascii")


def fetch_page(page_id):
    """Return (version:int, resource_types:set[str]) for a Confluence page."""
    url = f"{BASE_URL}/wiki/rest/api/content/{page_id}?expand=body.storage,version"
    req = urllib.request.Request(url, headers={
        "Authorization": _auth_header(), "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.load(resp)
    except urllib.error.HTTPError as e:
        sys.exit(f"ERROR: Confluence returned HTTP {e.code} for page {page_id}. "
                 f"Check the API token and read access to space SEKH.")
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: could not reach Confluence ({e.reason}).")
    version = int(data.get("version", {}).get("number", 0))
    storage = data.get("body", {}).get("storage", {}).get("value", "")
    return version, parse_types(storage)


def parse_types(storage_html):
    """Extract the set of resource type names from Confluence storage HTML."""
    text = re.sub(r"<br\s*/?>", "\n", storage_html, flags=re.I)
    text = re.sub(r"</(p|li|div|h[1-6])>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = (text.replace("&amp;", "&").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&nbsp;", " "))
    return {ln.strip() for ln in text.splitlines() if TYPE_RE.match(ln.strip())}


def load_baseline():
    if not os.path.exists(BASELINE_PATH):
        return {"providers": {}}
    with open(BASELINE_PATH) as f:
        return json.load(f)


def script_mapped_types(rel_path):
    """Terraform types already handled by an asset-count script's MAP."""
    path = os.path.join(ROOT, rel_path)
    if not os.path.exists(path):
        return set()
    with open(path) as f:
        return set(SCRIPT_MAP_RE.findall(f.read()))


def write_lists_and_baseline(live):
    """Rewrite supported-types/*.txt and providers.baseline.json deterministically."""
    os.makedirs(LISTS_DIR, exist_ok=True)
    baseline = {
        "_comment": "Auto-generated from Confluence by monitor/check_provider_pages.py. "
                    "Do not edit by hand.",
        "providers": {},
    }
    for key, info in PROVIDERS.items():
        version, types = live[key]
        ordered = sorted(types)
        with open(os.path.join(LISTS_DIR, f"{key}.txt"), "w") as f:
            f.write(f"# Firefly-supported {info['label']} Terraform resource types "
                    f"({len(ordered)}) - source: {info['title']} (Confluence SEKH)\n")
            f.write("\n".join(ordered) + "\n")
        baseline["providers"][key] = {
            "page_id": info["page_id"], "title": info["title"],
            "version": version, "count": len(ordered), "types": ordered,
        }
    with open(BASELINE_PATH, "w") as f:
        json.dump(baseline, f, indent=2)
        f.write("\n")


def main():
    old = load_baseline().get("providers", {})
    live = {key: fetch_page(info["page_id"]) for key, info in PROVIDERS.items()}

    any_change = False
    sections = []
    for key, info in PROVIDERS.items():
        _, live_types = live[key]
        base_types = set(old.get(key, {}).get("types", []))
        added = sorted(live_types - base_types)
        removed = sorted(base_types - live_types)
        bc, lc = len(base_types), len(live_types)

        if not (added or removed):
            sections.append(f"### {info['label']} — {lc} types (no change)\n")
            continue

        any_change = True
        page_url = f"{BASE_URL}/wiki/spaces/SEKH/pages/{info['page_id']}"
        delta = lc - bc
        lines = [f"### {info['label']} — {bc} → **{lc}** "
                 f"({'+' if delta >= 0 else ''}{delta})   ·   "
                 f"[Confluence source]({page_url})", ""]
        if added:
            lines.append(f"**Added ({len(added)}):**")
            lines += [f"- `{t}`" for t in added]
            lines.append("")
        if removed:
            lines.append(f"**Removed ({len(removed)}):**")
            lines += [f"- `{t}`" for t in removed]
            lines.append("")
        # Which newly-added types are not yet countable by the asset-count script?
        mapped = script_mapped_types(info["script"])
        unmapped_new = [t for t in added if t not in mapped]
        if unmapped_new:
            lines.append(f"**⚠ Script follow-up — not yet mapped in `{info['script']}`:**")
            lines += [f"- `{t}`  (add its cloud-native inventory type to the MAP if it has one)"
                      for t in unmapped_new]
            lines.append("")
        lines.append(f"**PDF follow-up:** regenerate `pdfs/Firefly-Supported-"
                     f"{info['label']}-Resource-Types.pdf` (now {lc} types).")
        lines.append("")
        sections.append("\n".join(lines))

    write_lists_and_baseline(live)

    if any_change:
        body = ("Provider coverage changed on Confluence. This PR updates the "
                "machine-readable lists (`supported-types/`) and the baseline "
                "(`monitor/providers.baseline.json`) automatically.\n\n"
                "**Manual follow-ups** (the job cannot do these safely): add any "
                "flagged mappings to the asset-count scripts, and regenerate the "
                "affected PDFs via Claude Design.\n\n---\n\n" + "\n".join(sections))
    else:
        body = "No changes across the AWS / Azure / GCP provider pages.\n\n" + "\n".join(sections)

    with open(REPORT_PATH, "w") as f:
        f.write(body)
    print(body)


if __name__ == "__main__":
    main()
