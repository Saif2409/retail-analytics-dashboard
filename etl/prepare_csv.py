"""Flatten the Online Retail II workbook into one CSV for bulk loading.

Deliberately does NOT clean the data. The only job here is Excel -> CSV with a
stable column order and ISO timestamps, so `\\copy` can stream it into a staging
table. Every business rule (cancellations, non-product SKUs, the overlapping
date window between the two sheets, missing customers) is handled in SQL, where
it is reviewable -- see sql/03_transform_facts.sql.

One column is added that is not in the source: source_sheet. The workbook's two
sheets overlap between 2010-12-01 and 2010-12-09, and keeping the provenance
lets sql/06_data_quality.sql prove the de-duplication actually worked.
"""

from __future__ import annotations

from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
WORKBOOK = ROOT / "data" / "raw" / "online_retail_II.xlsx"
OUT_CSV = ROOT / "data" / "processed" / "online_retail_II.csv"

# Source header -> staging column name.
COLUMNS = {
    "Invoice": "invoice_no",
    "StockCode": "stock_code",
    "Description": "description",
    "Quantity": "quantity",
    "InvoiceDate": "invoice_ts",
    "Price": "unit_price",
    "Customer ID": "customer_id",
    "Country": "country",
}

OUTPUT_ORDER = list(COLUMNS.values()) + ["source_sheet"]


def main() -> int:
    if not WORKBOOK.exists():
        raise SystemExit(f"Missing {WORKBOOK}. Run etl/download_dataset.py first.")

    OUT_CSV.parent.mkdir(parents=True, exist_ok=True)

    sheets = pd.read_excel(WORKBOOK, sheet_name=None, dtype={"Invoice": str, "StockCode": str})
    print(f"Sheets found: {list(sheets)}")

    frames = []
    for name, df in sheets.items():
        missing = set(COLUMNS) - set(df.columns)
        if missing:
            raise SystemExit(f"Sheet {name!r} is missing expected columns: {sorted(missing)}")

        df = df[list(COLUMNS)].rename(columns=COLUMNS)
        df["source_sheet"] = name
        print(
            f"  {name}: {len(df):>7,} rows  "
            f"{df['invoice_ts'].min():%Y-%m-%d} -> {df['invoice_ts'].max():%Y-%m-%d}"
        )
        frames.append(df)

    combined = pd.concat(frames, ignore_index=True)[OUTPUT_ORDER]

    # Customer ID arrives as float (NaN forces the column to float64); render it
    # as a clean integer string so the staging column can stay INTEGER.
    combined["customer_id"] = combined["customer_id"].astype("Int64")

    combined.to_csv(
        OUT_CSV,
        index=False,
        date_format="%Y-%m-%d %H:%M:%S",
        encoding="utf-8",
    )

    size_mb = OUT_CSV.stat().st_size / 1024 / 1024
    print(f"\nWrote {len(combined):,} rows -> {OUT_CSV} ({size_mb:.1f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
