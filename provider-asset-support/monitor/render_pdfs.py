#!/usr/bin/env python3
"""
Render the client-ready "Firefly-Supported <Cloud> Resource Types" PDFs from
the machine-readable lists, so the PDFs can never drift from supported-types/.

Input : monitor/providers.baseline.json (written by check_provider_pages.py)
        monitor/assets/logo-{white,color}.png (Firefly brand logos)
Output: pdfs/Firefly-Supported-{AWS,Azure,GCP}-Resource-Types.pdf

Output is deterministic (reportlab invariant mode, no timestamps): the same
lists always produce byte-identical PDFs, so git only sees a change when the
supported types actually change.

Requires: reportlab  (pip install reportlab)
"""

import json
import os
import sys

from reportlab.lib.colors import Color, HexColor
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen import canvas

MONITOR_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(MONITOR_DIR)                       # provider-asset-support/
BASELINE_PATH = os.path.join(MONITOR_DIR, "providers.baseline.json")
ASSETS_DIR = os.path.join(MONITOR_DIR, "assets")
PDF_DIR = os.path.join(ROOT, "pdfs")

LABELS = {"aws": "AWS", "azure": "Azure", "gcp": "GCP"}
CLOUD_NAMES = {"aws": "Amazon Web Services", "azure": "Microsoft Azure",
               "gcp": "Google Cloud Platform"}

# Firefly brand palette (same tokens as the QBR / one-pager decks)
DARK_BLUE = HexColor("#160A50")
BLUE = HexColor("#2E16A1")
PURPLE = HexColor("#6B39D0")
CYAN = HexColor("#0AFFDE")
LIGHT = HexColor("#C8BAF5")
MUTED_ON_DARK = HexColor("#8B7BC8")
CARD_BG = HexColor("#1D0E5E")
WHITE = HexColor("#FFFFFF")
# Light-page tones
INK = HexColor("#1B1340")
MUTED = HexColor("#6E6890")
ROW_TINT = HexColor("#F5F2FD")
RULE = HexColor("#E6E0F7")

PAGE_W, PAGE_H = letter
MARGIN = 44
GUTTER = 18
COLS = 2
COL_W = (PAGE_W - 2 * MARGIN - GUTTER * (COLS - 1)) / COLS
LEADING = 14
FONT, FONT_BOLD = "Helvetica", "Helvetica-Bold"
ITEM_SIZE = 8.6
HEADER_H = 196                       # first-page hero band
TOP_FIRST = PAGE_H - HEADER_H - 64   # baseline of first list row, page 1
TOP_REST = PAGE_H - 92               # baseline of first list row, later pages
BOTTOM = MARGIN + 30
CARD_W = 132                         # hero count card


def _logo(name):
    return ImageReader(os.path.join(ASSETS_DIR, name))


def _fit_size(text, size):
    """Shrink a long type name just enough to fit its column."""
    max_w = COL_W - 16
    while size > 6 and stringWidth(text, FONT, size) > max_w:
        size -= 0.2
    return size


def _draw_logo(c, img, x, y, height):
    iw, ih = img.getSize()
    c.drawImage(img, x, y, width=height * iw / ih, height=height, mask="auto")


def _gradient_bar(c, y, h):
    """Purple -> cyan rule, echoing the logo's gradient."""
    c.saveState()
    p = c.beginPath()
    p.rect(0, y, PAGE_W, h)
    c.clipPath(p, stroke=0, fill=0)
    c.linearGradient(0, y, PAGE_W, y, (PURPLE, BLUE, CYAN), (0, 0.45, 1), extend=False)
    c.restoreState()


def _hero(c, key, info, logo_white):
    top = PAGE_H
    base = PAGE_H - HEADER_H
    c.setFillColor(DARK_BLUE)
    c.rect(0, base, PAGE_W, HEADER_H, stroke=0, fill=1)

    # Soft glow shapes in the top-right corner
    c.saveState()
    p = c.beginPath()
    p.rect(0, base, PAGE_W, HEADER_H)
    c.clipPath(p, stroke=0, fill=0)
    for r, alpha, dx, dy in ((170, 0.35, 40, 10), (110, 0.30, -60, -50), (60, 0.25, 70, -110)):
        c.setFillColor(Color(BLUE.red, BLUE.green, BLUE.blue, alpha=alpha))
        c.circle(PAGE_W - 90 + dx, top - 40 + dy, r, stroke=0, fill=1)
    c.restoreState()
    _gradient_bar(c, base, 5)

    _draw_logo(c, logo_white, MARGIN, top - 62, 26)

    c.setFillColor(CYAN)
    c.setFont(FONT_BOLD, 8.5)
    c.drawString(MARGIN, top - 96, f"CLOUD COVERAGE  ·  {CLOUD_NAMES[key].upper()}")
    title = f"Supported {LABELS[key]} Resource Types"
    title_size = 25
    while stringWidth(title, FONT_BOLD, title_size) > PAGE_W - 2 * MARGIN - CARD_W - 20:
        title_size -= 0.5
    c.setFillColor(WHITE)
    c.setFont(FONT_BOLD, title_size)
    c.drawString(MARGIN, top - 126, title)
    c.setFillColor(LIGHT)
    c.setFont(FONT, 10.5)
    c.drawString(MARGIN, top - 148, "Resources Firefly inventories, codifies and governs,")
    c.drawString(MARGIN, top - 162, "listed by Terraform resource type.")

    # Count card
    cw, ch = CARD_W, 82
    cx, cy = PAGE_W - MARGIN - cw, top - 168
    c.setFillColor(CARD_BG)
    c.setStrokeColor(PURPLE)
    c.setLineWidth(1)
    c.roundRect(cx, cy, cw, ch, 10, stroke=1, fill=1)
    c.setFillColor(CYAN)
    c.setFont(FONT_BOLD, 34)
    c.drawCentredString(cx + cw / 2, cy + 36, str(info["count"]))
    c.setFillColor(LIGHT)
    c.setFont(FONT, 8.5)
    c.drawCentredString(cx + cw / 2, cy + 18, "supported resource types")

    # Intro under the band
    c.setFillColor(INK)
    c.setFont(FONT_BOLD, 11)
    c.drawString(MARGIN, base - 32, "Supported resource types")
    c.setFillColor(MUTED)
    c.setFont(FONT, 8.5)
    c.drawRightString(PAGE_W - MARGIN, base - 32,
                      "Coverage grows continuously - this list is updated automatically.")
    c.setStrokeColor(RULE)
    c.setLineWidth(0.7)
    c.line(MARGIN, base - 42, PAGE_W - MARGIN, base - 42)


def _continuation_header(c, key, logo_color):
    _gradient_bar(c, PAGE_H - 5, 5)
    _draw_logo(c, logo_color, MARGIN, PAGE_H - 56, 20)
    c.setFillColor(INK)
    c.setFont(FONT_BOLD, 10)
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - 46, f"Supported {LABELS[key]} Resource Types")
    c.setFillColor(MUTED)
    c.setFont(FONT, 8)
    c.drawRightString(PAGE_W - MARGIN, PAGE_H - 58, "continued")
    c.setStrokeColor(RULE)
    c.setLineWidth(0.7)
    c.line(MARGIN, PAGE_H - 70, PAGE_W - MARGIN, PAGE_H - 70)


def _footer(c, info, page_no, page_count):
    c.setStrokeColor(RULE)
    c.setLineWidth(0.7)
    c.line(MARGIN, MARGIN + 14, PAGE_W - MARGIN, MARGIN + 14)
    c.setFont(FONT, 7.5)
    c.setFillColor(MUTED)
    c.drawString(MARGIN, MARGIN, f"Source: Firefly provider coverage - {info['title']}, "
                                 f"revision {info['version']}")
    c.setFillColor(PURPLE)
    c.setFont(FONT_BOLD, 7.5)
    right = f"Page {page_no} of {page_count}"
    c.drawRightString(PAGE_W - MARGIN, MARGIN, right)
    c.setFillColor(MUTED)
    c.setFont(FONT, 7.5)
    c.drawRightString(PAGE_W - MARGIN - stringWidth(right, FONT_BOLD, 7.5) - 10, MARGIN,
                      "firefly.ai   |")


def _layout(types):
    """Split the sorted list into pages of COLS columns, filling column by column."""
    pages, i, first = [], 0, True
    while i < len(types) or not pages:
        top = TOP_FIRST if first else TOP_REST
        rows = int((top - BOTTOM) // LEADING) + 1
        if len(types) - i <= rows * COLS:          # last page: balance the columns
            rows = max(1, -(-(len(types) - i) // COLS))
        chunk = types[i:i + rows * COLS]
        pages.append([chunk[k * rows:(k + 1) * rows] for k in range(COLS)])
        i += rows * COLS
        first = False
    return pages


def _rows(c, columns, top):
    for col, items in enumerate(columns):
        x = MARGIN + col * (COL_W + GUTTER)
        for r, name in enumerate(items):
            y = top - r * LEADING
            if r % 2 == 0:
                c.setFillColor(ROW_TINT)
                c.roundRect(x, y - 4, COL_W, LEADING, 3, stroke=0, fill=1)
            c.setFillColor(PURPLE)
            c.roundRect(x + 6, y + 0.6, 3.2, 3.2, 0.8, stroke=0, fill=1)
            c.setFillColor(INK)
            c.setFont(FONT, _fit_size(name, ITEM_SIZE))
            c.drawString(x + 15, y, name)


def render(key, info, out_path, logo_white, logo_color):
    types = sorted(info["types"])
    pages = _layout(types)
    c = canvas.Canvas(out_path, pagesize=letter, invariant=1, pageCompression=1)
    c.setTitle(f"Firefly - Supported {LABELS[key]} Resource Types")
    c.setAuthor("Firefly")
    c.setSubject(f"{info['count']} supported {LABELS[key]} Terraform resource types")
    c.setCreator("toolbox/provider-asset-support/monitor/render_pdfs.py")

    for p, columns in enumerate(pages, start=1):
        if p == 1:
            _hero(c, key, info, logo_white)
            _rows(c, columns, TOP_FIRST)
        else:
            _continuation_header(c, key, logo_color)
            _rows(c, columns, TOP_REST)
        _footer(c, info, p, len(pages))
        c.showPage()
    c.save()


def main():
    if not os.path.exists(BASELINE_PATH):
        sys.exit(f"ERROR: {BASELINE_PATH} not found - run check_provider_pages.py first.")
    with open(BASELINE_PATH) as f:
        providers = json.load(f)["providers"]
    logo_white, logo_color = _logo("logo-white.png"), _logo("logo-color.png")
    os.makedirs(PDF_DIR, exist_ok=True)
    for key in LABELS:
        info = providers[key]
        out = os.path.join(PDF_DIR, f"Firefly-Supported-{LABELS[key]}-Resource-Types.pdf")
        render(key, info, out, logo_white, logo_color)
        print(f"wrote {os.path.relpath(out, ROOT)} ({info['count']} types)")


if __name__ == "__main__":
    main()
