#!/usr/bin/env python3
"""
Render the client-ready "Firefly-Supported <Cloud> Resource Types" PDFs from
the machine-readable lists, so the PDFs can never drift from supported-types/.

Input : monitor/providers.baseline.json (written by check_provider_pages.py)
Output: pdfs/Firefly-Supported-{AWS,Azure,GCP}-Resource-Types.pdf

Output is deterministic (reportlab invariant mode, no timestamps): the same
lists always produce byte-identical PDFs, so git only sees a change when the
supported types actually change.

Requires: reportlab  (pip install reportlab)
"""

import json
import os
import sys

from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import letter
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen import canvas

MONITOR_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(MONITOR_DIR)                       # provider-asset-support/
BASELINE_PATH = os.path.join(MONITOR_DIR, "providers.baseline.json")
PDF_DIR = os.path.join(ROOT, "pdfs")

LABELS = {"aws": "AWS", "azure": "Azure", "gcp": "GCP"}
CLOUD_NAMES = {"aws": "Amazon Web Services", "azure": "Microsoft Azure",
               "gcp": "Google Cloud Platform"}

# Firefly palette
PURPLE = HexColor("#1E0B4B")
PURPLE_SOFT = HexColor("#F3F0FA")
CYAN = HexColor("#00C2D8")
INK = HexColor("#1F1F29")
MUTED = HexColor("#6B6B7B")
RULE = HexColor("#E4E0F0")

PAGE_W, PAGE_H = letter
MARGIN = 44
GUTTER = 20
COLS = 2
COL_W = (PAGE_W - 2 * MARGIN - GUTTER * (COLS - 1)) / COLS
LEADING = 13.5
FONT, FONT_BOLD = "Helvetica", "Helvetica-Bold"
ITEM_SIZE = 8.6
HEADER_H = 150          # first-page header band
TOP_FIRST = PAGE_H - HEADER_H - 58
TOP_REST = PAGE_H - MARGIN - 18
BOTTOM = MARGIN + 26


def _fit_size(text, size):
    """Shrink a long type name just enough to fit its column."""
    max_w = COL_W - 12
    while size > 6 and stringWidth(text, FONT, size) > max_w:
        size -= 0.2
    return size


def _footer(c, info, page_no, page_count):
    c.setStrokeColor(RULE)
    c.setLineWidth(0.6)
    c.line(MARGIN, MARGIN + 12, PAGE_W - MARGIN, MARGIN + 12)
    c.setFont(FONT, 7.5)
    c.setFillColor(MUTED)
    c.drawString(MARGIN, MARGIN,
                 f"Source: Firefly Sales Engineering Knowledge Hub - {info['title']} "
                 f"(revision {info['version']})")
    c.drawRightString(PAGE_W - MARGIN, MARGIN, f"firefly.ai   |   Page {page_no} of {page_count}")


def _first_page_header(c, key, info):
    c.setFillColor(PURPLE)
    c.rect(0, PAGE_H - HEADER_H, PAGE_W, HEADER_H, stroke=0, fill=1)
    c.setFillColor(CYAN)
    c.rect(0, PAGE_H - HEADER_H, PAGE_W, 4, stroke=0, fill=1)

    c.setFillColor(CYAN)
    c.setFont(FONT_BOLD, 9)
    c.drawString(MARGIN, PAGE_H - 44, "FIREFLY  |  CLOUD COVERAGE")
    c.setFillColor(HexColor("#FFFFFF"))
    c.setFont(FONT_BOLD, 24)
    c.drawString(MARGIN, PAGE_H - 76, f"Supported {LABELS[key]} Resource Types")
    c.setFont(FONT, 10.5)
    c.setFillColor(HexColor("#CFC8E6"))
    c.drawString(MARGIN, PAGE_H - 98,
                 f"{CLOUD_NAMES[key]} - listed by Terraform resource type")

    # Count badge on the right of the band
    count = str(info["count"])
    c.setFillColor(CYAN)
    c.setFont(FONT_BOLD, 34)
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - 74, count)
    c.setFont(FONT, 8.5)
    c.setFillColor(HexColor("#CFC8E6"))
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - 90, "supported resource types")

    # Intro line under the band
    c.setFillColor(INK)
    c.setFont(FONT, 9.5)
    c.drawString(MARGIN, PAGE_H - HEADER_H - 30,
                 f"Resource types Firefly inventories, codifies and governs in {LABELS[key]}. "
                 f"This list is kept up to date automatically.")


def _layout(types):
    """Split the sorted list into pages of COLS columns, filling column by column."""
    pages, i = [], 0
    first = True
    while i < len(types) or not pages:
        top = TOP_FIRST if first else TOP_REST
        rows = int((top - BOTTOM) // LEADING)
        chunk = types[i:i + rows * COLS]
        pages.append([chunk[k * rows:(k + 1) * rows] for k in range(COLS)])
        i += rows * COLS
        first = False
    return pages


def render(key, info, out_path):
    types = sorted(info["types"])
    pages = _layout(types)
    c = canvas.Canvas(out_path, pagesize=letter, invariant=1, pageCompression=1)
    c.setTitle(f"Firefly - Supported {LABELS[key]} Resource Types")
    c.setAuthor("Firefly")
    c.setSubject(f"{info['count']} supported {LABELS[key]} Terraform resource types")
    c.setCreator("toolbox/provider-asset-support/monitor/render_pdfs.py")

    for p, columns in enumerate(pages, start=1):
        if p == 1:
            _first_page_header(c, key, info)
            top = TOP_FIRST
        else:
            c.setFillColor(PURPLE)
            c.setFont(FONT_BOLD, 10)
            c.drawString(MARGIN, PAGE_H - MARGIN, f"Supported {LABELS[key]} Resource Types")
            c.setFillColor(MUTED)
            c.setFont(FONT, 8.5)
            c.drawRightString(PAGE_W - MARGIN, PAGE_H - MARGIN, "continued")
            top = TOP_REST

        for col, items in enumerate(columns):
            x = MARGIN + col * (COL_W + GUTTER)
            for r, name in enumerate(items):
                y = top - r * LEADING
                if r % 2 == 0:
                    c.setFillColor(PURPLE_SOFT)
                    c.rect(x, y - 3.6, COL_W, LEADING, stroke=0, fill=1)
                c.setFillColor(CYAN)
                c.circle(x + 5, y + 2.9, 1.5, stroke=0, fill=1)
                c.setFillColor(INK)
                c.setFont(FONT, _fit_size(name, ITEM_SIZE))
                c.drawString(x + 11, y, name)

        _footer(c, info, p, len(pages))
        c.showPage()
    c.save()


def main():
    if not os.path.exists(BASELINE_PATH):
        sys.exit(f"ERROR: {BASELINE_PATH} not found - run check_provider_pages.py first.")
    with open(BASELINE_PATH) as f:
        providers = json.load(f)["providers"]
    os.makedirs(PDF_DIR, exist_ok=True)
    for key in LABELS:
        info = providers[key]
        out = os.path.join(PDF_DIR, f"Firefly-Supported-{LABELS[key]}-Resource-Types.pdf")
        render(key, info, out)
        print(f"wrote {os.path.relpath(out, ROOT)} ({info['count']} types)")


if __name__ == "__main__":
    main()
