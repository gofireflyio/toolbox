# Provider Asset Support

Reference material and tooling for **which cloud resource types Firefly supports**,
and for **estimating how many supported assets** a prospect/customer has in their
cloud. Everything here derives from the canonical "Provider" pages in the Sales
Engineering Knowledge Hub (Confluence, space `SEKH`).

## Contents

```
provider-asset-support/
├── pdfs/                         Client-ready one-pagers of supported types (per cloud)
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
    ├── check_provider_pages.py
    └── providers.baseline.json
```

## The asset-count scripts

Each script is **read-only** — it only calls list/describe/query APIs — and prints a
per-type breakdown, a grand total, and a CSV. The total is a **lower bound**: it counts
only resource types the cloud's native inventory service exposes as discrete objects, so
child/config sub-resources Firefly also codifies are not separately counted.

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
  it reads the three Confluence pages and rewrites `supported-types/*.txt` and
  `monitor/providers.baseline.json`.
- If anything changed it **opens/updates a PR** (assigned to `@glengol`) whose description
  lists the added/removed types and a checklist of manual follow-ups. If nothing changed,
  it does nothing — no PR.

Two things the job intentionally does **not** auto-edit, because they need a human:

1. **Script mappings** — a newly supported type only becomes countable once its
   cloud-native inventory type (e.g. `microsoft.compute/virtualmachines`) is added to the
   relevant script's `MAP`. The PR flags exactly which new types are missing a mapping.
2. **PDFs** — regenerated via Claude Design using the Firefly brand system. The PR flags
   which ones are now out of date.

After you add mappings / regenerate PDFs, merging the PR makes the new baseline current.

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

To refresh the lists locally (e.g. to seed or test):

```bash
CONFLUENCE_EMAIL=you@firefly.ai CONFLUENCE_API_TOKEN=xxxx \
  python3 monitor/check_provider_pages.py
```
