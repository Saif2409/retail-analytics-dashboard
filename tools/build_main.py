"""Assemble the full PBIP: report shell, theme, pages, and the .pbip entry point."""

import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from build_report import (  # noqa: E402
    ACCENT, BAD, DEFN, GOOD, INK, MUTED, PAGES, REPO, REPORT,
    S_PAGES, S_PBIP, S_PBIR, S_REPORT, S_VERSION, write,
)
import build_pages  # noqa: E402

THEME_NAME = "RetailAnalyticsTheme"


def build_theme():
    theme = {
        "name": THEME_NAME,
        "dataColors": [
            ACCENT, "#5B8DEF", "#8FB4F5", GOOD, "#4FBE93",
            "#F0A202", "#F5C45E", BAD, "#E07B80", "#8A8F98",
        ],
        "foreground": INK,
        "foregroundNeutralSecondary": MUTED,
        "background": "#FFFFFF",
        "backgroundLight": "#F4F6F8",
        "tableAccent": ACCENT,
        "good": GOOD,
        "bad": BAD,
        "neutral": MUTED,
        "textClasses": {
            "title": {"fontFace": "Segoe UI Semibold", "fontSize": 12, "color": INK},
            "label": {"fontFace": "Segoe UI", "fontSize": 9, "color": MUTED},
            "callout": {"fontFace": "Segoe UI Semibold", "fontSize": 24, "color": INK},
        },
        "visualStyles": {
            "*": {
                "*": {
                    "background": [{"show": True, "transparency": 0}],
                    "border": [{"show": True, "color": {"solid": {"color": "#E3E7EB"}},
                                "radius": 8}],
                    "dropShadow": [{"show": False}],
                }
            }
        },
    }
    theme_dir = REPORT / "StaticResources" / "SharedResources" / "BaseThemes"
    write(theme_dir / f"{THEME_NAME}.json", theme)


def build_shell():
    write(REPORT / ".platform", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/"
                   "platformProperties/2.0.0/schema.json",
        "metadata": {"type": "Report", "displayName": "RetailAnalytics"},
        "config": {"version": "2.0",
                   "logicalId": "c8b52e31-6d44-4f02-9a7e-3b2d0f5c8e21"},
    })

    write(REPORT / "definition.pbir", {
        "$schema": S_PBIR,
        "version": "4.0",
        "datasetReference": {"byPath": {"path": "../RetailAnalytics.SemanticModel"}},
    })

    write(DEFN / "version.json", {
        "$schema": S_VERSION,
        "version": "2.0.0",
    })

    write(DEFN / "report.json", {
        "$schema": S_REPORT,
        "themeCollection": {
            "baseTheme": {"name": THEME_NAME, "reportVersionAtImport": "5.55",
                          "type": "SharedResources"}
        },
        "layoutOptimization": "None",
        "resourcePackages": [{
            "name": "SharedResources",
            "type": "SharedResources",
            "items": [{"name": THEME_NAME, "path": f"BaseThemes/{THEME_NAME}.json",
                       "type": "BaseTheme"}],
        }],
        "settings": {
            "useStylableVisualContainerHeader": True,
            "defaultFilterActionIsDataFilter": True,
        },
    })

    write(PAGES / "pages.json", {
        "$schema": S_PAGES,
        "pageOrder": build_pages.PAGE_ORDER,
        "activePageName": build_pages.PAGE_ORDER[0],
    })

    write(REPO / "powerbi" / "RetailAnalytics.pbip", {
        "$schema": S_PBIP,
        "version": "1.0",
        "artifacts": [{"report": {"path": "RetailAnalytics.Report"}}],
        "settings": {"enableAutoRecovery": True},
    })


def main():
    if PAGES.exists():
        shutil.rmtree(PAGES)
    build_theme()
    for builder in build_pages.BUILDERS:
        builder()
    build_shell()

    files = sorted(p for p in REPORT.rglob("*") if p.is_file())
    print(f"Wrote {len(files)} report files:")
    for f in files:
        print("  " + str(f.relative_to(REPO)))


if __name__ == "__main__":
    main()
