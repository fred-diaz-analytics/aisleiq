🇺🇸 English | 🇧🇷 [Português](README.pt-BR.md)

# AisleIQ

![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)
![Python](https://img.shields.io/badge/python-3.11-blue.svg)
![CI](https://github.com/fred-diaz-analytics/aisleiq/actions/workflows/pull-request.yml/badge.svg)

Medallion-architecture (bronze/silver/gold) data pipeline on Databricks for retail execution
KPIs (on-shelf presence, out-of-stock, price compliance, POS materials, extra displays, shelf
share) and field promoter visit compliance. Built as a **Databricks Asset Bundle**: a
Lakeflow Declarative Pipeline (the current name for what used to be Delta Live Tables) for
silver/gold, orchestrated by a Job (bronze + pipeline trigger).

The data is **100% synthetic**, generated deterministically by
[`data/lib_geracao.py`](data/lib_geracao.py). No PII, safe for a public repository.

> Full documentation (per-layer architecture, data dictionary) in [`docs/`](docs/index.md).
> See also the [Documentation site](#documentation-site) section below.

## Table of contents

- [Tech stack](#tech-stack)
- [Architecture](#architecture)
- [Bundle structure](#bundle-structure)
- [Unity Catalog catalogs](#unity-catalog-catalogs)
- [How to run](#how-to-run)
- [Tests](#tests)
- [KPIs (gold layer)](#kpis-gold-layer)
- [Dimensions (gold layer)](#dimensions-gold-layer)
- [Documentation site](#documentation-site)
- [License](#license)

## Tech stack

- **[Databricks](https://www.databricks.com/)**: Databricks Asset Bundle, Lakeflow Declarative
  Pipelines, Unity Catalog, Jobs, Delta Lake
- **[Supabase Storage](https://supabase.com/storage)**: S3-compatible object storage (where
  bronze ingests its files from)
- **Python 3.11**: synthetic data generator, export/upload scripts, tests
- **SQL**: all silver/gold transformations (Lakeflow Declarative Pipelines)
- **[MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/)**: documentation site
- **pytest, ruff, yamllint**: tests and lint, running in CI (GitHub Actions)

## Architecture

```
data/lib_geracao.py ──► local parquet (data/execucao_pdv/, data/atendimento/)
        │  (job_diario.py --upload-supabase)
        ▼
Supabase Storage (S3-compatible)
        │  (Job: bronze_ingest.py, runs 2x — one per domain)
        ▼
Bronze  (Delta Tables, catalog.bronze)          — raw snapshot, 1 file = 1 day, idempotent
        │  (Lakeflow Declarative Pipeline)
        ▼
Silver  (Materialized Views, catalog.silver)    — typed, deduplicated, validated (EXPECT/DROP ROW)
        │
        ▼
Gold    (Materialized Views, catalog.gold)      — 8 KPIs + 2 dimensions (dim_loja, dim_produto)
```

Besides the daily flow (PDV execution + visit compliance), two **master data** domains
(`lojas`/stores, `produtos`/products) run on demand, full-reload, outside the daily job/schedule.
See [`docs/arquitetura.md`](docs/arquitetura.md#dado-mestre-lojas-e-produtos) (Portuguese).

- **Bronze runs as a plain Job Task**, outside the Lakeflow Declarative Pipeline (a deliberate
  choice, see [`bronze_ingest.py`](src/pipelines/trade_analytics/transformations/bronze/bronze_ingest.py)):
  a single parametrized notebook (`prefix`/`file_regex`/`table_name` via `base_parameters`) runs
  twice, once per domain (`execucao_pdv`, `atendimentos`). Incremental ingestion via a
  `source_date` watermark, configurable lookback, idempotent writes via `replaceWhere`, and
  per-file failure isolation.
- **Silver and Gold are the Lakeflow Declarative Pipeline** (`resources/pipelines.trade_analytics.yml`),
  defined in plain SQL (`CREATE OR REFRESH MATERIALIZED VIEW ... EXPECT ...`) under
  [`src/pipelines/trade_analytics/transformations/{silver,gold}/`](src/pipelines/trade_analytics/transformations/).

## Bundle structure

```
databricks.yml                  # bundle "trade_analytics" — dev/prod targets, variables
resources/
  jobs.trade_analytics.yml      # Jobs: trade_analytics (daily) + trade_analytics_lojas/_produtos (on demand)
  pipelines.trade_analytics.yml # Lakeflow Declarative Pipeline (silver + gold)
  schemas.yml                   # creates the bronze/silver/gold UC schemas
  volumes.yml                   # bronze.raw_files staging volume
src/pipelines/trade_analytics/transformations/
  bronze/bronze_ingest.py           # parametrized notebook (execucao_pdv/atendimentos, incremental)
  bronze/bronze_ingest_lojas.py     # stores master data, full-reload
  bronze/bronze_ingest_produtos.py  # products master data, full-reload
  bronze/bronze_lib.py              # pure logic (regex/date parsing), tested offline
  silver/*.sql                      # execucao_pdv, atendimentos, lojas (5 MVs), produtos (3 MVs)
  gold/*.sql                        # 8 KPIs + dim_loja + dim_produto
data/
  lib_geracao.py                # deterministic synthetic generator (fixed seed)
  backfill_2026.py              # historical seed (2026-01-01 to 2026-08-10)
  upload_backfill.py            # uploads the historical backfill to Supabase
  job_diario.py                 # daily entrypoint, catch-up mode
  export_dim_loja.py, export_dim_produto.py    # derive the master-data CSVs
  upload_dim_loja.py, upload_dim_produto.py    # upload the master-data CSVs to Supabase
  execucao_pdv/, atendimento/   # generated parquet, frozen snapshot through 2026-08-21 (see note below)
tests/unit/                     # pytest — pure logic from bronze_lib.py, no cluster/network
docs/                           # documentation site (MkDocs + Material)
```

## Unity Catalog catalogs

The bundle uses the `catalog` variable (`aisleiq_dev` in dev, `aisleiq_prod` in prod, see
`targets.*.variables.catalog` in [`databricks.yml`](databricks.yml)) to create the
`bronze`/`silver`/`gold` schemas and the `bronze.raw_files` volume. **The catalog itself must
already exist** in the metastore before deploying: the bundle creates schemas, not catalogs.

`dev` deliberately does not use `mode: development`: that mode would prefix resources
(including the UC schemas) with `dev_<user>_`, breaking this project's requirement for exact
resource names.

## How to run

### Prerequisites

- **Python 3.11+**
- **[Databricks CLI](https://docs.databricks.com/dev-tools/cli/index.html)** installed and
  authenticated (`databricks auth login`) against your workspace
- **A Unity Catalog catalog already created** in your metastore, for the `dev` target (and
  another for `prod`, if you use it). Create it via the **UI**: Catalog Explorer → *Create
  Catalog*. There isn't a reliable CLI command for this on new workspaces, so don't try to
  automate it via `databricks catalogs create`
- **A [Supabase](https://supabase.com/) project (or any S3-compatible storage)**, where
  bronze reads the generated files from. In Supabase: create a project, enable
  *Storage*, and grab the S3 endpoint + credentials from *Storage → Settings → S3 Connection*.
  Supabase's free tier is enough for this project's volume.

> ℹ️ **Databricks Free Edition** (the current one, different from the older Community Edition)
> already supports Unity Catalog, Jobs, and Lakeflow Declarative Pipelines, enough to run this
> project at no cost.

`s3_endpoint` (used in the commands below) has no default on purpose. It's never committed;
always pass it via `--var="s3_endpoint=..."` or the `BUNDLE_VAR_s3_endpoint` environment
variable.

### Step by step

```bash
# 1. Python environment
python -m venv .venv
.venv\Scripts\activate        # Windows (Linux/Mac: source .venv/bin/activate)
pip install -r requirements-dev.txt

# 2. Storage credentials
cd data
cp ../.env.example .env       # fill in your Supabase S3 endpoint + credentials

# 3. Generate and upload the synthetic data (facts + master data)
python backfill_2026.py --out-dir .            # historical seed, once
python upload_backfill.py --out-dir .          # uploads the backfill to Supabase
python export_dim_loja.py --out-dir . && python upload_dim_loja.py --out-dir .
python export_dim_produto.py --out-dir . && python upload_dim_produto.py --out-dir .
cd ..

# 4. Edit databricks.yml: replace <SEU_WORKSPACE> with your workspace's real host
#    (targets.dev.workspace.host and targets.prod.workspace.host)

# 5. Validate
databricks bundle validate -t dev --var="s3_endpoint=https://<your-project>.storage.supabase.co/storage/v1/s3"

# 6. Create the secret scope with the S3 credentials (never hardcoded in code/config)
databricks secrets create-scope supabase
databricks secrets put-secret supabase access_key_id
databricks secrets put-secret supabase secret_access_key

# 7. Deploy
databricks bundle deploy -t dev --var="s3_endpoint=https://<your-project>.storage.supabase.co/storage/v1/s3"

# 8. Populate the master data (once, or whenever stores/products change) --
#    REQUIRED before step 9: the same Lakeflow Pipeline materializes the
#    lojas/produtos MVs alongside execucao_pdv/atendimentos (same silver/**
#    + gold/** glob), so skipping this step makes step 9 fail trying to read
#    bronze.lojas/bronze.produtos, which wouldn't exist yet.
databricks bundle run trade_analytics_lojas -t dev --var="s3_endpoint=https://<your-project>.storage.supabase.co/storage/v1/s3"
databricks bundle run trade_analytics_produtos -t dev --var="s3_endpoint=https://<your-project>.storage.supabase.co/storage/v1/s3"

# 9. Run the daily job (bronze x2 + silver/gold pipeline)
databricks bundle run trade_analytics -t dev --var="s3_endpoint=https://<your-project>.storage.supabase.co/storage/v1/s3"
```

### Ongoing operation: daily catch-up

After the initial setup above, this runs continuously (it's not a one-time step):

`job_diario.py` runs in **catch-up mode**: without `--data`, it detects the last day already
generated on its own and fills in every missing business day up to today (skipping weekends).
A single run after several idle days covers the whole gap.

```bash
python data/job_diario.py --dominio todos --out-dir data --upload-supabase
```

Meant to run via a local scheduler (Task Scheduler/cron) every day, before the Databricks
Job's first scheduled run.

> ℹ️ **Frozen data snapshot**: the parquet files committed under `data/execucao_pdv/` and
> `data/atendimento/` are a fixed snapshot through **2026-08-21**, small, deterministic, no
> PII, kept so the repo is instantly runnable without generating anything first. The daily
> catch-up keeps running locally and uploading to Supabase as usual, but files generated after
> that date are **not** committed going forward. `.gitignore` only blocks new/untracked dates;
> it doesn't remove what's already tracked, so this needs no maintenance. Run
> `backfill_2026.py`/`job_diario.py` yourself if you want more recent synthetic data locally.

## Tests

```bash
pytest tests/unit      # pure logic from bronze_lib.py — no cluster, no network, runs in any CI
ruff check .
yamllint .
```

## KPIs (gold layer)

| Table | Grain | Description |
|---|---|---|
| `execucao_pdv_presenca` | store/product/day | % of evaluations where the product was present on shelf |
| `execucao_pdv_ruptura` | store/product/day | % of evaluations where the product was out of stock |
| `execucao_pdv_preco` | store/product/day | Price charged — average, min, max |
| `execucao_pdv_mpdv` | store/product/day | % of evaluations with point-of-sale material activated |
| `execucao_pdv_ponto_extra` | store/product/day | Total and average extra display space won |
| `execucao_pdv_share_gondola` | store/product/day | Average shelf share |
| `atendimento_cumprimento_visita` | promoter/store/day | Visit compliance rate — OK vs. NP (couldn't) vs. X (cancelled) |
| `atendimento_tempo_loja` | promoter/store/day | Average/total time spent in store |

## Dimensions (gold layer)

| Table | Grain | Description |
|---|---|---|
| `dim_loja` | 1 per store | Chain, category, city, state, region — joined via `id_loja` in BI |
| `dim_produto` | 1 per product | Brand, category, size — joined via `id_produto` in BI |

None of the 8 KPI tables reference these dimensions via a SQL foreign key. The join happens
in the BI model.

Full column-by-column detail in [`docs/dicionario.md`](docs/dicionario.md) (Portuguese).

## Documentation site

The content in [`docs/`](docs/) (Portuguese) is published as a static site via
[MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/):

```bash
pip install mkdocs mkdocs-material   # already in requirements-dev.txt
mkdocs serve     # http://127.0.0.1:8000
mkdocs build     # generates a static site/
```

## License

[MIT](LICENSE)
