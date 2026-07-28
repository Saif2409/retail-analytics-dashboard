# tools/ — report authoring scripts

> **The committed PBIR JSON under `powerbi/RetailAnalytics.Report/` is the
> source of truth.** Running `build_main.py` **deletes and regenerates** the
> entire `definition/pages/` tree. Any edit made in Power BI Desktop and saved
> will be destroyed. Do not run this unless you intend exactly that.

These scripts authored the report definition in the first place. Hand-writing
39 interdependent PBIR JSON files is not practical — one wrong schema version
string or filter enum and Power BI refuses the whole project with a stack trace
rather than a line number. Generating them from one place made the fix-and-retry
loop tractable.

They are kept because they are still the fastest way to make a *systematic*
change — restyling every visual, renumbering schema versions, relaying out a
page grid. For editing a single visual, use Power BI Desktop.

## Usage

```bash
python tools/build_main.py
```

Paths resolve relative to the repo root, so it works from a fresh clone.

| File | Role |
|---|---|
| `build_report.py` | Schema constants, palette, field-expression and visual writers |
| `build_pages.py` | The three pages, their visuals, filters and layout |
| `build_main.py` | Theme, report shell, `.pbip` entry point; run this one |

## Two things that cost real time

**Schema versions are not guessable.** Power BI validates every `$schema`
against an exact allow-list and rejects anything else, including plausible
values like `1.4.0`. The accepted URIs are embedded as strings in the DLLs under
the Power BI Desktop package's `bin` folder and can be recovered by scanning
them — that is where the constants at the top of `build_report.py` came from.
They are specific to Desktop 2.156; a much newer build may accept different ones.

**Filter enums are positional and silent when wrong.**
`QueryComparisonKind` is `0 Equal, 1 GreaterThan, 2 GreaterThanOrEqual,
3 LessThan, 4 LessThanOrEqual`. Using `2` where `4` was meant turns a
"top 10 products" filter into "rank >= 10" — which renders happily, shows almost
every product, and looks like a sorting bug rather than a filter bug.
