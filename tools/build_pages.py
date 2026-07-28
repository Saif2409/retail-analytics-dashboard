"""Page + visual definitions for the RetailAnalytics PBIR report."""

from build_report import (
    ACCENT, BAD, GOOD, H, INK, MUTED, PAGE_BG, PAGES, S_PAGE, W,
    boolean, card_bg, colour, column, hierarchy, kpi_card, measure, num,
    textbox, title_obj, txt, visual, write,
)

# =============================================================================
# Filter helpers
# =============================================================================

def complete_month_filter():
    """Pin the page to whole months only.

    The extract stops on 2011-12-09, so December 2011 holds nine trading days
    against December 2010's thirty-one. Unfiltered, the YoY visuals report a
    collapse that never happened.
    """
    return {
        "name": "filterCompleteMonth",
        "field": {"Column": {"Expression": {"SourceRef": {"Entity": "dim_date"}},
                             "Property": "is_complete_month"}},
        "type": "Categorical",
        "filter": {
            "Version": 2,
            "From": [{"Name": "d", "Entity": "dim_date", "Type": 0}],
            "Where": [{
                "Condition": {"In": {
                    "Expressions": [{"Column": {
                        "Expression": {"SourceRef": {"Source": "d"}},
                        "Property": "is_complete_month"}}],
                    "Values": [[{"Literal": {"Value": "true"}}]],
                }}
            }],
        },
        "howCreated": "User",
    }


def rank_filter(name, top_n):
    """Keep only the top N rows, using the [Product Revenue Rank] measure.

    A measure comparison rather than a native Top N filter: the rank measure
    already exists, uses ALLSELECTED so it respects slicers, and the resulting
    JSON is a plain comparison that is far less brittle than the TopN shape.
    """
    return {
        "name": name,
        "field": {"Measure": {"Expression": {"SourceRef": {"Entity": "_Measures"}},
                              "Property": "Product Revenue Rank"}},
        "type": "Advanced",
        "filter": {
            "Version": 2,
            "From": [{"Name": "m", "Entity": "_Measures", "Type": 0}],
            "Where": [{
                "Condition": {"Comparison": {
                    # QueryComparisonKind: 0 Equal, 1 GreaterThan,
                    # 2 GreaterThanOrEqual, 3 LessThan, 4 LessThanOrEqual.
                    # 4 is the one that means "top N".
                    "ComparisonKind": 4,
                    "Left": {"Measure": {"Expression": {"SourceRef": {"Source": "m"}},
                                         "Property": "Product Revenue Rank"}},
                    "Right": {"Literal": {"Value": f"{top_n}L"}},
                }}
            }],
        },
        "howCreated": "User",
    }


# =============================================================================
# Page scaffolding
# =============================================================================

def page(page_id, display_name, filters=None):
    node = {
        "$schema": S_PAGE,
        "name": page_id,
        "displayName": display_name,
        "displayOption": "FitToPage",
        "height": H,
        "width": W,
        "objects": {
            "background": [{"properties": {"color": colour(PAGE_BG),
                                           "transparency": num(0)}}],
        },
    }
    if filters:
        node["filterConfig"] = {"filters": filters}
    d = PAGES / page_id
    write(d / "page.json", node)
    return d


def header(d, title, subtitle):
    textbox(d, "txtHeader", 20, 12, 780, 74, [
        (title + "\n", 18, INK, True),
        (subtitle, 9.5, MUTED, False),
    ], order=0)


def slicer(d, name, entity, col, label, x, y, w, h, order):
    visual(
        d, name, "slicer", x, y, w, h,
        query={"Values": {"projections": [column(entity, col)]}},
        objects={"header": [{"properties": {"show": boolean(False)}}]},
        vc_objects={"title": title_obj(label, size=9, color=MUTED), **card_bg()},
        order=order,
    )


def sorted_desc(entity_prop):
    """Sort a visual by a measure, descending."""
    return {
        "sort": [{
            "field": {"Measure": {"Expression": {"SourceRef": {"Entity": "_Measures"}},
                                  "Property": entity_prop}},
            "direction": "Descending",
        }],
        "isDefaultSort": True,
    }


# =============================================================================
# Page 1 -- Executive Overview
# =============================================================================

def build_overview():
    d = page("pgOverview", "Executive Overview", filters=[complete_month_filter()])

    header(d, "Retail Performance Overview",
           "Online Retail II  |  Dec 2009 - Nov 2011  |  complete months only  |  "
           "revenue is net of returns")

    slicer(d, "slcYear", "dim_date", "year", "Year", 812, 20, 200, 54, 1)
    slicer(d, "slcRegion", "dim_country", "region", "Region", 1024, 20, 236, 54, 2)

    for i, (name, m, label) in enumerate([
        ("cardRevenue", "Net Revenue", "Net revenue"),
        ("cardOrders", "Total Orders", "Orders"),
        ("cardCustomers", "Active Customers", "Active customers"),
        ("cardAOV", "Avg Order Value", "Avg order value"),
        ("cardReturn", "Return Rate %", "Return rate"),
    ]):
        kpi_card(d, name, 20 + i * 248, 88, 240, 92, m, label, order=10 + i)

    visual(
        d, "chtMonthly", "lineClusteredColumnComboChart", 20, 194, 800, 252,
        query={
            "Category": {"projections": [column("dim_date", "year_month")]},
            "Y": {"projections": [measure("Net Revenue")]},
            "Y2": {"projections": [measure("Revenue 3M Moving Avg")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "legend": [{"properties": {"show": boolean(True), "position": txt("Top")}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8.5)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8.5)}}],
        },
        vc_objects={"title": title_obj(
            "Net revenue by month, with 3-month moving average"), **card_bg()},
        order=20,
    )

    # A bar chart rather than a map. Power BI ships with map visuals disabled
    # under Options > Global > Security, so a map renders as an empty box with
    # a "visuals are disabled" notice on any machine that has not opted in --
    # including anyone who clones this repo. A bar also reads exact values
    # better than bubble area, which is what this comparison actually needs.
    visual(
        d, "chtCountry", "barChart", 832, 194, 428, 252,
        query={
            "Category": {"projections": [column("dim_country", "country")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj("Net revenue by country"), **card_bg()},
        order=21,
        sort_measure="Net Revenue",
    )

    # YoY kept on its own axis rather than layered onto the trend chart -- a
    # percentage and an absolute do not share an axis usefully.
    visual(
        d, "chtYoY", "columnChart", 20, 458, 520, 240,
        query={
            "Category": {"projections": [column("dim_date", "year_month")]},
            "Y": {"projections": [measure("Revenue YoY %")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(GOOD)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj(
            "Revenue growth vs same month last year"), **card_bg()},
        order=22,
    )

    visual(
        d, "chtTopProducts", "barChart", 552, 458, 356, 240,
        query={
            "Category": {"projections": [column("dim_product", "description")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj("Top 10 products by net revenue"), **card_bg()},
        order=23,
        filters=[rank_filter("filterTop10", 10)],
        sort_measure="Net Revenue",
    )

    visual(
        d, "chtCategory", "donutChart", 920, 458, 340, 240,
        query={
            "Category": {"projections": [column("dim_product", "product_category")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={"legend": [{"properties": {"show": boolean(True),
                                            "position": txt("Right"),
                                            "fontSize": num(8)}}]},
        vc_objects={"title": title_obj("Revenue by category (derived)"), **card_bg()},
        order=24,
    )


# =============================================================================
# Page 2 -- Product Performance (the drill-down page)
# =============================================================================

def build_products():
    d = page("pgProducts", "Product Performance", filters=[complete_month_filter()])

    header(d, "Product Performance",
           "Expand Category to Product in the matrix  |  categories are derived by "
           "keyword heuristic, approximate by design")

    slicer(d, "slcCategory", "dim_product", "product_category", "Category",
           812, 20, 448, 54, 1)

    for i, (name, m, label) in enumerate([
        ("cardUnits", "Units Sold", "Units sold"),
        ("cardBasket", "Avg Basket Size", "Avg basket size"),
        ("cardReturned", "Returned Revenue", "Returned revenue"),
    ]):
        kpi_card(d, name, 20 + i * 248, 88, 240, 92, m, label, order=10 + i)

    # The drill-down centrepiece: Category -> Product hierarchy on rows.
    visual(
        d, "mtxProducts", "pivotTable", 20, 194, 760, 504,
        query={
            "Rows": {"projections": [
                hierarchy("dim_product", "Product Drill", "Category"),
                hierarchy("dim_product", "Product Drill", "Product"),
            ]},
            "Values": {"projections": [
                measure("Net Revenue"),
                measure("Units Sold"),
                measure("Total Orders"),
                measure("Return Rate %"),
                measure("% of Total Revenue"),
            ]},
        },
        objects={
            "grid": [{"properties": {"gridVertical": boolean(True)}}],
            "columnHeaders": [{"properties": {"fontSize": num(9), "bold": boolean(True)}}],
            "values": [{"properties": {"fontSize": num(9)}}],
            "subTotals": [{"properties": {"rowSubtotals": boolean(True)}}],
        },
        vc_objects={"title": title_obj(
            "Category â†’ Product  (click + to drill)"), **card_bg()},
        order=20,
    )

    visual(
        d, "chtCatRevenue", "barChart", 792, 194, 468, 246,
        query={
            "Category": {"projections": [column("dim_product", "product_category")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj("Net revenue by category"), **card_bg()},
        order=21,
        sort_measure="Net Revenue",
    )

    # Units against revenue separates high-volume/low-margin lines from the
    # opposite -- the pattern a single ranked bar chart hides.
    visual(
        d, "sctProducts", "scatterChart", 792, 452, 468, 246,
        query={
            "Category": {"projections": [column("dim_product", "description")]},
            "X": {"projections": [measure("Units Sold")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj("Units vs revenue, by product"), **card_bg()},
        order=22,
        filters=[rank_filter("filterTop200", 200)],
    )


# =============================================================================
# Page 3 -- Customers & Retention
# =============================================================================

def build_customers():
    d = page("pgCustomers", "Customers & Retention",
             filters=[complete_month_filter()])

    header(d, "Customers & Retention",
           "RFM scored against the last date in the extract, not today  |  guest "
           "checkouts carry revenue but cannot be scored, so they show as (Blank)")

    slicer(d, "slcSegment", "customer_rfm", "rfm_segment", "RFM segment",
           812, 20, 448, 54, 1)

    # Deliberately NOT [New Customers] / [Returning Customers] here. Over the
    # full period every customer was new exactly once, so those cards read
    # "5,847 new / 0 returning" -- true but useless. The split is only
    # meaningful per period, which is what the monthly chart below shows.
    for i, (name, m, label) in enumerate([
        ("cardActive", "Active Customers", "Active customers"),
        ("cardRepeat", "Repeat Rate %", "Repeat purchase rate"),
        ("cardRevPerCust", "Revenue per Customer", "Revenue per customer"),
    ]):
        kpi_card(d, name, 20 + i * 248, 88, 240, 92, m, label, order=10 + i)

    visual(
        d, "chtNewVsReturning", "columnChart", 20, 194, 620, 250,
        query={
            "Category": {"projections": [column("dim_date", "year_month")]},
            "Y": {"projections": [measure("New Customers"),
                                  measure("Returning Customers")]},
        },
        objects={
            "legend": [{"properties": {"show": boolean(True), "position": txt("Top")}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj(
            "New vs returning customers by month"), **card_bg()},
        order=20,
    )

    visual(
        d, "chtSegments", "barChart", 652, 194, 608, 250,
        query={
            "Category": {"projections": [column("customer_rfm", "rfm_segment")]},
            "Y": {"projections": [measure("Net Revenue")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(ACCENT)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8.5)}}],
        },
        vc_objects={"title": title_obj("Net revenue by RFM segment"), **card_bg()},
        order=21,
        sort_measure="Net Revenue",
    )

    # Cohort matrix. Reads from the standalone pre-aggregated table -- see the
    # modelling note in cohort_retention.tmdl.
    visual(
        d, "mtxCohort", "pivotTable", 20, 456, 780, 242,
        query={
            "Rows": {"projections": [column("cohort_retention", "cohort_month")]},
            "Columns": {"projections": [column("cohort_retention", "months_since")]},
            "Values": {"projections": [measure("Retention %")]},
        },
        objects={
            "columnHeaders": [{"properties": {"fontSize": num(8)}}],
            "rowHeaders": [{"properties": {"fontSize": num(8)}}],
            "values": [{"properties": {"fontSize": num(8)}}],
            "subTotals": [{"properties": {"rowSubtotals": boolean(False),
                                          "columnSubtotals": boolean(False)}}],
        },
        vc_objects={"title": title_obj(
            "Cohort retention % by months since first purchase"), **card_bg()},
        order=22,
    )

    visual(
        d, "sctRfm", "scatterChart", 812, 456, 448, 242,
        # X and Y must be aggregates. Raw columns here make the scatter refuse
        # to render with "Remove Values to display x- and y-axis pairs".
        query={
            "Category": {"projections": [column("customer_rfm", "customer_label")]},
            "X": {"projections": [measure("Avg Recency (days)")]},
            "Y": {"projections": [measure("Customer Lifetime Value")]},
        },
        objects={
            "dataPoint": [{"properties": {"fill": colour(BAD)}}],
            "categoryAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
            "valueAxis": [{"properties": {"show": boolean(True), "fontSize": num(8)}}],
        },
        vc_objects={"title": title_obj(
            "Recency vs lifetime value"), **card_bg()},
        order=23,
    )


PAGE_ORDER = ["pgOverview", "pgProducts", "pgCustomers"]
BUILDERS = [build_overview, build_products, build_customers]
