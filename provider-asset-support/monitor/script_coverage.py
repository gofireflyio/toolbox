#!/usr/bin/env python3
"""
Keep the asset-count scripts in step with the supported-type lists.

Every supported Terraform type in supported-types/<provider>.txt must appear
in exactly one of three arrays in scripts/firefly_<provider>_asset_count.sh:

  MAP_VALS          counted (paired with a cloud-native type in MAP_KEYS)
  COUNTED_AS_OTHER  counted under another type's native type (AWS, GCP)
  NOT_COUNTABLE     the cloud's inventory service does not expose it

This script:

  1. With --fix, removes types that are no longer supported from all three
     arrays (a MAP_VALS entry is removed together with its MAP_KEYS pair).
     This is the only edit it makes - it never invents a mapping.
  2. Lists supported types that are in none of the arrays ("unclassified").
     These need a cloud-native type, which the Confluence list does not give;
     the sync workflow hands them to Claude (when an ANTHROPIC_API_KEY secret
     is set) and otherwise leaves them as a PR checklist.
  3. Checks every MAP_KEYS entry against the cloud's official list of
     inventory types (AWS Config ResourceType enum, Azure Resource Graph type
     reference, Cloud Asset Inventory supported types) and reports entries that
     are not real types, since those are never counted.

Dependency-free (Python 3 standard library only).

Usage
  script_coverage.py [--fix] [--official-dir DIR] [--json PATH]
                     [--report PATH] [--check]

  --official-dir DIR  cache/read the official type lists here (<provider>.txt)
  --json PATH         write {"<provider>": {"unclassified": [...],
                      "dead_keys": [...]}} as JSON
  --report PATH       append a markdown coverage section to PATH
  --check             exit 1 if a supported type is unclassified or in more
                      than one array, or an array holds an unsupported type
  --strict            with --check, also exit 1 if a MAP key is not on the
                      official list (off by default: those lists have gaps)
"""

import argparse
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROVIDERS = {
    "aws":   {"label": "AWS",   "prefix": "aws_",
              "script": "scripts/firefly_aws_asset_count.sh",
              "source": "AWS Config ResourceType enum (botocore)"},
    "azure": {"label": "Azure", "prefix": "azurerm_",
              "script": "scripts/firefly_azure_asset_count.sh",
              "source": "Azure Resource Graph type reference"},
    "gcp":   {"label": "GCP",   "prefix": "google_",
              "script": "scripts/firefly_gcp_asset_count.sh",
              "source": "Cloud Asset Inventory supported asset types"},
}

# Each provider's official type list is the union of these sources. For AWS
# the documentation lists far more recorded types than the API's ResourceType
# enum (which lags behind), so both are used.
OFFICIAL_URLS = {
    "aws": ["https://raw.githubusercontent.com/boto/botocore/develop/botocore/data/config/2014-11-12/service-2.json",
            "https://docs.aws.amazon.com/config/latest/developerguide/resource-config-reference.html"],
    "azure": ["https://raw.githubusercontent.com/MicrosoftDocs/azure-docs/main/articles/governance/resource-graph/reference/supported-tables-resources.md"],
    "gcp": ["https://cloud.google.com/asset-inventory/docs/supported-asset-types"],
}

# MAP keys that are valid although the official list omits them. Keep the
# reason next to each one.
KNOWN_VALID_KEYS = {
    "azure": {
        # Returned by RecoveryServicesResources (verified live, Oct 2026) but
        # missing from the Resource Graph type reference page.
        "microsoft.recoveryservices/vaults/backupfabrics/protectioncontainers",
        # Azure Database for PostgreSQL Single Server, retired March 2025 and
        # dropped from the reference; kept so any leftover servers still count.
        "microsoft.dbforpostgresql/servers",
    },
}


# ----------------------------------------------------------------- parsing ---

def array_span(text, name):
    """(start, end) of the lines between 'NAME=(' and its closing ')'."""
    m = re.search(r"^%s=\(\n(.*?)^\)" % re.escape(name), text, re.S | re.M)
    return (m.start(1), m.end(1)) if m else None


def array_entries(text, name):
    span = array_span(text, name)
    if not span:
        return []
    return re.findall(r'^\s*"([^"]*)"\s*$', text[span[0]:span[1]], re.M)


def remove_entries(text, name, drop_indexes):
    """Remove the drop_indexes-th quoted entries (0-based) from array NAME."""
    span = array_span(text, name)
    if not span or not drop_indexes:
        return text
    out, idx = [], 0
    for line in text[span[0]:span[1]].splitlines(keepends=True):
        if re.match(r'^\s*"[^"]*"\s*$', line):
            if idx in drop_indexes:
                idx += 1
                continue
            idx += 1
        out.append(line)
    return text[:span[0]] + "".join(out) + text[span[1]:]


def stray_entries(text):
    """Line numbers of bare '"..."' lines that are not inside a NAME=( ... ) array."""
    stray, inside = [], False
    for n, line in enumerate(text.splitlines(), 1):
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=\($", line):
            inside = True
        elif inside and line.startswith(")"):
            inside = False
        elif not inside and re.match(r'^\s*"[^"]*"\s*$', line):
            stray.append(n)
    return stray


def supported_types(key):
    path = os.path.join(ROOT, "supported-types", f"{key}.txt")
    prefix = PROVIDERS[key]["prefix"]
    with open(path) as f:
        return {l.strip() for l in f if l.strip().startswith(prefix)}


# ---------------------------------------------------------- official lists ---

def fetch(url, attempts=3):
    req = urllib.request.Request(url, headers={"User-Agent": "firefly-toolbox-sync"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return r.read().decode("utf-8")
        except (http.client.IncompleteRead, urllib.error.URLError, TimeoutError):
            if attempt == attempts - 1:
                raise
            time.sleep(5 * (attempt + 1))


def parse_official(key, raw):
    if key == "aws":
        if raw.lstrip().startswith("{"):
            return set(json.loads(raw)["shapes"]["ResourceType"]["enum"])
        return set(re.findall(r"AWS::[A-Za-z0-9]+::[A-Za-z0-9]+", raw))
    if key == "azure":
        # Lines look like "- microsoft.Compute/disks (Disks)" or "- microsoft.x/y".
        return {t.lower() for t in re.findall(r"^- ([A-Za-z0-9.]+/[A-Za-z0-9./]+)\b", raw, re.M)}
    raw = raw.replace("<wbr>", "")
    return set(re.findall(r"[a-z0-9.-]+\.googleapis\.com/[A-Za-z0-9]+", raw))


def official_types(key, cache_dir):
    """Official inventory types for a provider, or None if unavailable."""
    cache = os.path.join(cache_dir, f"{key}.txt") if cache_dir else None
    if cache and os.path.exists(cache):
        with open(cache) as f:
            return {l.strip() for l in f if l.strip()}
    types = set()
    for url in OFFICIAL_URLS[key]:
        try:
            types |= parse_official(key, fetch(url))
        except Exception as e:  # network/format problems must not break the sync
            print(f"warning: could not load {url}: {e}", file=sys.stderr)
    if len(types) < 50:  # a page format change, not a real list
        print(f"warning: official {key} type list parsed to {len(types)} types; ignoring",
              file=sys.stderr)
        return None
    if cache:
        os.makedirs(cache_dir, exist_ok=True)
        with open(cache, "w") as f:
            f.write("\n".join(sorted(types)) + "\n")
    return types


def native_base(key, map_key):
    """The official type a MAP key refers to, or None for synthetic keys."""
    if map_key.endswith("#embedded"):  # child config counted from parent properties
        return None
    base = map_key.split("#", 1)[0]
    if key == "gcp":
        base = base.replace("iam-policy/", "", 1)
    return base.lower() if key == "azure" else base


# -------------------------------------------------------------------- main ---

def analyse(key, cache_dir, fix):
    info = PROVIDERS[key]
    path = os.path.join(ROOT, info["script"])
    with open(path) as f:
        text = f.read()
    supported = supported_types(key)

    stray = stray_entries(text)
    if stray:
        sys.exit(f"{info['script']}: quoted entries outside any array (lines {stray}); "
                 "they would run as commands")
    keys, vals = array_entries(text, "MAP_KEYS"), array_entries(text, "MAP_VALS")
    if len(keys) != len(vals):
        sys.exit(f"{info['script']}: MAP_KEYS ({len(keys)}) and MAP_VALS ({len(vals)}) differ in length")

    removed = []
    if fix:
        drop_map = {i for i, v in enumerate(vals) if v not in supported}
        removed += [vals[i] for i in sorted(drop_map)]
        text = remove_entries(text, "MAP_KEYS", drop_map)
        text = remove_entries(text, "MAP_VALS", drop_map)
        for name in ("COUNTED_AS_OTHER", "NOT_COUNTABLE"):
            entries = array_entries(text, name)
            drop = {i for i, v in enumerate(entries) if v not in supported}
            removed += [entries[i] for i in sorted(drop)]
            text = remove_entries(text, name, drop)
        if removed:
            with open(path, "w") as f:
                f.write(text)
        keys, vals = array_entries(text, "MAP_KEYS"), array_entries(text, "MAP_VALS")

    mapped = set(vals)
    other = set(array_entries(text, "COUNTED_AS_OTHER"))
    notc = set(array_entries(text, "NOT_COUNTABLE"))
    official = official_types(key, cache_dir)
    dead = []
    if official is not None:
        known = KNOWN_VALID_KEYS.get(key, set())
        dead = sorted({k for k in keys
                       if native_base(key, k) is not None
                       and native_base(key, k) not in official
                       and native_base(key, k) not in known})
    return {
        "supported": len(supported),
        "mapped": len(mapped & supported),
        "other": len(other & supported),
        "not_countable": len(notc & supported),
        "unclassified": sorted(supported - mapped - other - notc),
        "double": sorted((mapped & other) | (mapped & notc) | (other & notc)),
        "stale": sorted((mapped | other | notc) - supported),
        "dead_keys": dead,
        "official_checked": official is not None,
        "removed": removed,
    }


def report_md(results):
    lines = ["", "---", "", "### Asset-count script coverage", "",
             "| Provider | Supported | Counted | Counted under another type | Not countable | Unclassified |",
             "|---|---|---|---|---|---|"]
    for key, r in results.items():
        lines.append(f"| {PROVIDERS[key]['label']} | {r['supported']} | {r['mapped']} | {r['other']} "
                     f"| {r['not_countable']} | {len(r['unclassified'])} |")
    lines.append("")
    for key, r in results.items():
        info = PROVIDERS[key]
        if r["removed"]:
            lines.append(f"**{info['label']}: removed from `{info['script']}` (no longer supported):** "
                         + ", ".join(f"`{t}`" for t in r["removed"]))
            lines.append("")
        if r["unclassified"]:
            lines.append(f"**⚠ {info['label']}: not yet in `{info['script']}`** — add each to `MAP_KEYS`/"
                         "`MAP_VALS` with its inventory type, or to `COUNTED_AS_OTHER` / `NOT_COUNTABLE`:")
            lines += [f"- [ ] `{t}`" for t in r["unclassified"]]
            lines.append("")
        if r["dead_keys"]:
            lines.append(f"**⚠ {info['label']}: MAP keys not in the {info['source']}** "
                         "(never counted; fix or move the Terraform type to `NOT_COUNTABLE`):")
            lines += [f"- [ ] `{k}`" for k in r["dead_keys"]]
            lines.append("")
        if r["double"]:
            lines.append(f"**⚠ {info['label']}: in more than one array:** "
                         + ", ".join(f"`{t}`" for t in r["double"]))
            lines.append("")
        if not r["official_checked"]:
            lines.append(f"_{info['label']}: official type list unavailable this run; MAP keys not validated._")
            lines.append("")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true")
    ap.add_argument("--official-dir")
    ap.add_argument("--json")
    ap.add_argument("--report")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    results = {key: analyse(key, args.official_dir, args.fix) for key in PROVIDERS}
    md = report_md(results)
    print(md)
    if args.json:
        with open(args.json, "w") as f:
            json.dump({k: {"unclassified": r["unclassified"], "dead_keys": r["dead_keys"]}
                       for k, r in results.items()}, f, indent=2)
    if args.report:
        with open(args.report, "a") as f:
            f.write(md)
    if args.check and any(r["unclassified"] or r["double"] or r["stale"]
                          or (args.strict and r["dead_keys"]) for r in results.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
