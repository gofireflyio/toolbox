# Provider Asset Support

Reference material and tooling for **which cloud resource types Firefly supports**,
and for **estimating how many supported assets** a prospect/customer has in their
cloud. Everything here derives from the canonical "Provider" pages in the Sales
Engineering Knowledge Hub (Confluence, space `SEKH`).

## Contents

```
provider-asset-support/
├── pdfs/                         Client-ready lists of supported types (per cloud, auto-generated)
│   ├── Firefly-Supported-AWS-Resource-Types.pdf
│   ├── Firefly-Supported-Azure-Resource-Types.pdf
│   └── Firefly-Supported-GCP-Resource-Types.pdf
├── scripts/                      Read-only asset-count scripts to share with technical stakeholders
│   ├── firefly_aws_asset_count.sh
│   ├── firefly_azure_asset_count.sh
│   └── firefly_gcp_asset_count.sh
├── supported-types/              Machine-readable supported-type lists (auto-synced from Confluence)
│   ├── aws.txt   ├── azure.txt   └── gcp.txt
└── monitor/                      Automation that keeps the above in sync
    ├── check_provider_pages.py   Confluence -> supported-types/ + baseline + PR report
    ├── render_pdfs.py            baseline -> branded pdfs/ (deterministic, needs reportlab)
    ├── assets/                   Firefly logos used by the PDFs
    └── providers.baseline.json
```

## The asset-count scripts

Each script is **read-only** — it only calls list/describe/query APIs — and prints a
per-type breakdown, a grand total, and a CSV. The total is a **lower bound**: it counts
only resource types the cloud's native inventory service exposes, so data-plane objects
and some child/config sub-resources Firefly also codifies are not counted.

The Azure script also queries the `AuthorizationResources`, `PolicyResources`,
`RecoveryServicesResources` and `DnsResources` tables (role assignments, policy
assignments/exemptions/definitions, Azure Backup items, private DNS records), counts
child config embedded in parent resources (subnets, NSG rules, LB rules/probes/pools,
VNet peerings, Key Vault access policies, ...), and splits Linux/Windows VMs and
VMSS, web/function/Logic App Standard apps and AI Foundry hubs/projects. It prints how
many of the supported types it can count; `-v` lists the ones Resource Graph does not
expose (kept in the script's `NOT_COUNTABLE` list).

| Cloud | Data source | Prereqs | Scope |
|-------|-------------|---------|-------|
| AWS   | AWS Config advanced queries | `aws` v2, `jq`; Config recorder enabled; `config:SelectResourceConfig` | per-region or org-wide Config aggregator |
| Azure | Azure Resource Graph        | `az` (logged in), `jq`; `Reader` role | subscriptions or a management group |
| GCP   | Cloud Asset Inventory       | `gcloud`; `cloudasset.googleapis.com` enabled; `roles/cloudasset.viewer` | project / folder / organization |

```bash
# AWS  – all enabled regions in the current account (or -a for an org aggregator)
./scripts/firefly_aws_asset_count.sh
./scripts/firefly_aws_asset_count.sh -a MY_CONFIG_AGGREGATOR

# Azure – all accessible subscriptions (or -s SUB_ID, or -m MGMT_GROUP)
./scripts/firefly_azure_asset_count.sh

# GCP  – a project (or -f FOLDER_ID, or -o ORG_ID)
./scripts/firefly_gcp_asset_count.sh -p my-project
```

Each script supports `-h` for full usage.

## How maintenance works

The supported-type lists grow as Firefly increases coverage. A GitHub Action
(`.github/workflows/sync-provider-support.yml`) keeps this folder in step:

- **Every 2 weeks** (1st & 15th, 08:00 UTC — also runnable on demand from the Actions tab)
  it reads the three Confluence pages, rewrites `supported-types/*.txt` and
  `monitor/providers.baseline.json`, and **regenerates the three PDFs** from those lists.
- If anything changed it **opens/updates a PR** (assigned to `@LioriFR23`) whose description
  lists the added/removed types vs `main` and a checklist of script follow-ups. If nothing
  changed, it does nothing — no PR.
- If a sync PR is already open, the next run **builds on top of that branch** (no
  force-push), so anything you commit to it is kept, and the PR description is refreshed.
- **Safety guard:** if a provider page parses to 0 types or shrinks by more than 20%, the
  run fails without touching anything — that usually means the Confluence page format
  changed. If a large removal is real, re-run it from the Actions tab with **allow_shrink**.

One thing the job intentionally does **not** auto-edit: **script mappings**. A newly
supported type only becomes countable once its cloud-native inventory type (e.g.
`microsoft.compute/virtualmachines`) is added to the relevant script's `MAP` — Confluence
only lists Terraform names, so that mapping needs a human. The PR flags exactly which new
types are missing a mapping, and which removed types are still mapped (and would be
over-counted). Commit those fixes to the PR branch, then merge. For Azure, a new type
that Resource Graph cannot see goes in the script's `NOT_COUNTABLE` list instead, so it
is not flagged again.

Note: the asset-count scripts do **not** read `supported-types/*.txt`; their `MAP` is the
list of what they count. The `.txt` lists feed the PDFs and the PR report.

### Setup (one-time)

The workflow needs two repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|--------|-------|
| `CONFLUENCE_EMAIL`     | an Atlassian account email with read access to space `SEKH` |
| `CONFLUENCE_API_TOKEN` | an API token for that account (id.atlassian.com → API tokens) |

> Repository secrets are encrypted and are **never** exposed to forks, PRs, or logs —
> safe to set even though this repo is public.

Also enable **Settings → Actions → General → Workflow permissions →
"Allow GitHub Actions to create and approve pull requests"** so the job can open the PR.

To refresh the lists and PDFs locally (e.g. to seed or test):

```bash
pip install reportlab==4.2.5 pillow==13.0.0
CONFLUENCE_EMAIL=you@firefly.ai CONFLUENCE_API_TOKEN=xxxx \
  python3 monitor/check_provider_pages.py
python3 monitor/render_pdfs.py
```
