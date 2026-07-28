<#
.SYNOPSIS
    Build the retail_analytics warehouse end to end.

.DESCRIPTION
    Downloads the dataset if absent, flattens it to CSV, then runs every SQL
    step in order. Safe to re-run: each step drops and rebuilds what it owns.

    Authentication is never handled here. psql picks up credentials from
    %APPDATA%\postgresql\pgpass.conf or the PGPASSWORD environment variable.
    Nothing in this repo should ever contain a password.

.EXAMPLE
    .\etl\run_pipeline.ps1
    .\etl\run_pipeline.ps1 -SkipDownload
    .\etl\run_pipeline.ps1 -PgBin 'C:\Program Files\PostgreSQL\16\bin'
#>
[CmdletBinding()]
param(
    [string] $PgBin    = 'C:\Program Files\PostgreSQL\17\bin',
    [string] $PgHost   = 'localhost',
    [int]    $PgPort   = 5432,
    [string] $PgUser   = 'postgres',
    [string] $Database = 'retail_analytics',
    [switch] $SkipDownload
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Psql     = Join-Path $PgBin 'psql.exe'
$Csv      = Join-Path $RepoRoot 'data\processed\online_retail_II.csv'

if (-not (Test-Path $Psql)) {
    throw "psql not found at $Psql. Pass -PgBin with the correct path."
}

# \copy in 02_load_staging.sql resolves its path against psql's working
# directory, so every step runs from the repo root regardless of where this
# script was invoked from.
Push-Location $RepoRoot
try {

function Invoke-Sql {
    param([string] $File, [string] $Db = $Database, [string[]] $Vars = @())

    $name = Split-Path $File -Leaf
    Write-Host "`n=== $name " -NoNewline -ForegroundColor Cyan
    Write-Host ('=' * [Math]::Max(0, 60 - $name.Length)) -ForegroundColor Cyan

    $args = @(
        '-U', $PgUser, '-h', $PgHost, '-p', $PgPort, '-d', $Db,
        '-w',                      # never prompt; fail fast if auth is missing
        '-v', 'ON_ERROR_STOP=1',   # a failed statement fails the whole script
        '-f', $File
    )
    foreach ($v in $Vars) { $args += @('-v', $v) }

    & $Psql @args
    if ($LASTEXITCODE -ne 0) {
        throw "$name failed with exit code $LASTEXITCODE"
    }
}

$started = Get-Date

# ---------------------------------------------------------------------------
# 1. Source data
# ---------------------------------------------------------------------------
if (-not $SkipDownload) {
    Write-Host "`n=== Preparing source data ===" -ForegroundColor Cyan
    py -3 (Join-Path $RepoRoot 'etl\download_dataset.py')
    if ($LASTEXITCODE -ne 0) { throw 'download_dataset.py failed' }

    if (-not (Test-Path $Csv)) {
        py -3 (Join-Path $RepoRoot 'etl\prepare_csv.py')
        if ($LASTEXITCODE -ne 0) { throw 'prepare_csv.py failed' }
    } else {
        Write-Host "CSV already present, skipping conversion."
    }
}

if (-not (Test-Path $Csv)) {
    throw "Missing $Csv. Run without -SkipDownload."
}

# ---------------------------------------------------------------------------
# 2. Warehouse
#
# 00 runs against the maintenance database because CREATE DATABASE cannot run
# inside the database it is creating.
# ---------------------------------------------------------------------------
$sql = Join-Path $RepoRoot 'sql'

Invoke-Sql (Join-Path $sql '00_create_database.sql') -Db 'postgres'
Invoke-Sql (Join-Path $sql '01_schema.sql')
Invoke-Sql (Join-Path $sql '02_load_staging.sql')
Invoke-Sql (Join-Path $sql '03_transform_dimensions.sql')
Invoke-Sql (Join-Path $sql '04_transform_facts.sql')
Invoke-Sql (Join-Path $sql '05_indexes.sql')
Invoke-Sql (Join-Path $sql '06_analysis_views.sql')
Invoke-Sql (Join-Path $sql '07_data_quality.sql')

$elapsed = (Get-Date) - $started
Write-Host "`nPipeline completed in $([Math]::Round($elapsed.TotalSeconds, 1))s." -ForegroundColor Green
Write-Host "Open powerbi\RetailAnalytics.pbip in Power BI Desktop and refresh." -ForegroundColor Green

}
finally {
    Pop-Location
}
