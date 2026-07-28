"""Download the UCI 'Online Retail II' dataset into data/raw/.

Source: https://archive.ics.uci.edu/dataset/502/online+retail+ii
Licence: CC BY 4.0. ~1.07M transactions from a UK-based online gift retailer,
2009-12-01 through 2011-12-09, split across two Excel sheets.

Idempotent: skips the download if the extracted workbook is already present.
"""

from __future__ import annotations

import hashlib
import io
import sys
import urllib.request
import zipfile
from pathlib import Path

URL = "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
WORKBOOK = RAW_DIR / "online_retail_II.xlsx"

# archive.ics.uci.edu rejects the default urllib agent with 403.
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)


def download() -> bytes:
    req = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
    print(f"GET {URL}")
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = resp.read()
    print(f"  {len(payload) / 1024 / 1024:.1f} MB received")
    return payload


def main() -> int:
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    if WORKBOOK.exists():
        print(f"Already present, skipping download: {WORKBOOK}")
        return 0

    payload = download()
    print(f"  sha256={hashlib.sha256(payload).hexdigest()}")

    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        names = zf.namelist()
        print(f"  archive contains: {names}")
        match = next((n for n in names if n.lower().endswith(".xlsx")), None)
        if match is None:
            print("ERROR: no .xlsx inside the archive", file=sys.stderr)
            return 1
        WORKBOOK.write_bytes(zf.read(match))

    print(f"Extracted -> {WORKBOOK} ({WORKBOOK.stat().st_size / 1024 / 1024:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
