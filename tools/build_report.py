"""Author the PBIR report definition for RetailAnalytics.

Writes real, committed PBIR files into powerbi/RetailAnalytics.Report/.
This is a one-time authoring tool kept out of the repo -- the repo holds the
generated JSON, which is what Power BI Desktop opens and what git diffs.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
REPORT = REPO / "powerbi" / "RetailAnalytics.Report"
DEFN = REPORT / "definition"
PAGES = DEFN / "pages"

SCHEMA = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition"

# Exact versions Power BI Desktop 2.156 validates against, extracted from the
# schema URIs embedded in its own binaries. These are NOT interchangeable --
# the app rejects any version string it does not know, including plausible ones
# like 1.4.0. Each object type has its own independent version line.
S_VISUAL = f"{SCHEMA}/visualContainer/1.8.0/schema.json"
S_PAGE = f"{SCHEMA}/page/1.5.0/schema.json"
S_PAGES = f"{SCHEMA}/pagesMetadata/1.1.0/schema.json"
S_REPORT = f"{SCHEMA}/report/1.3.0/schema.json"
S_VERSION = f"{SCHEMA}/versionMetadata/1.0.0/schema.json"

# The project-level schemas are built at runtime by the app rather than stored
# as literals, so these follow the pattern its validator reported.
S_PBIP = ("https://developer.microsoft.com/json-schemas/fabric/pbip/"
          "pbipProperties/1.0.0/schema.json")
S_PBIR = ("https://developer.microsoft.com/json-schemas/fabric/item/report/"
          "definitionProperties/1.0.0/schema.json")
S_PBISM = ("https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/"
           "definitionProperties/1.0.0/schema.json")

W, H = 1280, 720

# --- palette -----------------------------------------------------------------
INK = "#1A1D21"
MUTED = "#6B7280"
ACCENT = "#2F6FED"
GOOD = "#1F9D6B"
BAD = "#D0454C"
CARD_BG = "#FFFFFF"
PAGE_BG = "#F4F6F8"


def write(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False), encoding="utf-8")


# --- field expression helpers ------------------------------------------------

def measure(name: str):
    return {
        "field": {
            "Measure": {
                "Expression": {"SourceRef": {"Entity": "_Measures"}},
                "Property": name,
            }
        },
        "queryRef": f"_Measures.{name}",
        "nativeQueryRef": name,
    }


def column(entity: str, name: str, alias: str | None = None):
    return {
        "field": {
            "Column": {
                "Expression": {"SourceRef": {"Entity": entity}},
                "Property": name,
            }
        },
        "queryRef": f"{entity}.{name}",
        "nativeQueryRef": alias or name,
    }


def hierarchy(entity: str, hname: str, alias: str | None = None):
    return {
        "field": {
            "HierarchyLevel": {
                "Expression": {
                    "Hierarchy": {
                        "Expression": {"SourceRef": {"Entity": entity}},
                        "Hierarchy": hname,
                    }
                },
                "Level": alias,
            }
        },
        "queryRef": f"{entity}.{hname}.{alias}",
        "nativeQueryRef": alias,
    }


def lit(value):
    if isinstance(value, str):
        return {"Literal": {"Value": f"'{value}'"}}
    if isinstance(value, bool):
        return {"Literal": {"Value": "true" if value else "false"}}
    return {"Literal": {"Value": str(value)}}


# --- object property helpers -------------------------------------------------

def txt(value):
    return {"expr": {"Literal": {"Value": f"'{value}'"}}}


def num(value):
    return {"expr": {"Literal": {"Value": f"{value}D"}}}


def boolean(value):
    return {"expr": {"Literal": {"Value": "true" if value else "false"}}}


def colour(hex_value):
    return {"solid": {"color": {"expr": {"Literal": {"Value": f"'{hex_value}'"}}}}}


def title_obj(text, size=11, color=INK, align="left"):
    return [{
        "properties": {
            "text": txt(text),
            "fontSize": num(size),
            "fontColor": colour(color),
            "alignment": txt(align),
            "bold": boolean(True),
        }
    }]


def card_bg():
    return {
        "background": [{"properties": {"color": colour(CARD_BG), "transparency": num(0)}}],
        "border": [{"properties": {"show": boolean(True), "color": colour("#E3E7EB"), "radius": num(8)}}],
        "dropShadow": [{"properties": {"show": boolean(False)}}],
    }


_counter = [0]


def vid(prefix: str) -> str:
    _counter[0] += 1
    return f"{prefix}{_counter[0]:03d}"


def visual(page_dir: Path, name, vtype, x, y, w, h, query=None, objects=None,
           vc_objects=None, order=0, filters=None, sort_measure=None,
           sort_direction="Descending"):
    node = {
        "$schema": S_VISUAL,
        "name": name,
        "position": {"x": x, "y": y, "z": order, "width": w, "height": h, "tabOrder": order},
        "visual": {
            "visualType": vtype,
            "drillFilterOtherVisuals": True,
        },
    }
    if query:
        node["visual"]["query"] = {"queryState": query}
        # Without an explicit sort, Power BI falls back to sorting by the
        # category field, which on a ranked bar chart means alphabetical --
        # the top seller ends up buried in the middle.
        if sort_measure:
            node["visual"]["query"]["sortDefinition"] = {
                "sort": [{
                    "field": {
                        "Measure": {
                            "Expression": {"SourceRef": {"Entity": "_Measures"}},
                            "Property": sort_measure,
                        }
                    },
                    "direction": sort_direction,
                }],
                "isDefaultSort": True,
            }
    if objects:
        node["visual"]["objects"] = objects
    if vc_objects:
        node["visual"]["visualContainerObjects"] = vc_objects
    if filters:
        node["filterConfig"] = {"filters": filters}
    write(page_dir / "visuals" / name / "visual.json", node)


def textbox(page_dir: Path, name, x, y, w, h, runs, order=0):
    """runs: list of (text, size, colour, bold)"""
    paragraphs = [{
        "textRuns": [
            {
                "value": t,
                "textStyle": {
                    "fontSize": f"{s}pt",
                    "color": c,
                    "fontWeight": "bold" if b else "normal",
                    "fontFamily": "Segoe UI",
                },
            }
            for (t, s, c, b) in runs
        ]
    }]
    node = {
        "$schema": S_VISUAL,
        "name": name,
        "position": {"x": x, "y": y, "z": order, "width": w, "height": h, "tabOrder": order},
        "visual": {
            "visualType": "textbox",
            "objects": {"general": [{"properties": {"paragraphs": paragraphs}}]},
            "drillFilterOtherVisuals": True,
        },
    }
    write(page_dir / "visuals" / name / "visual.json", node)


def kpi_card(page_dir, name, x, y, w, h, measure_name, label, order=0, fmt=None):
    objects = {
        "labels": [{"properties": {
            "fontSize": num(24), "color": colour(INK), "bold": boolean(True),
        }}],
        "categoryLabels": [{"properties": {
            "show": boolean(True), "fontSize": num(9), "color": colour(MUTED),
        }}],
    }
    if fmt:
        objects["labels"][0]["properties"]["labelDisplayUnits"] = num(fmt)
    visual(
        page_dir, name, "card", x, y, w, h,
        query={"Values": {"projections": [measure(measure_name)]}},
        objects=objects,
        vc_objects={"title": title_obj(label, size=10, color=MUTED), **card_bg()},
        order=order,
    )
