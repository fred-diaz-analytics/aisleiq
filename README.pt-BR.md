🇺🇸 [English](README.md) | 🇧🇷 Português

# AisleIQ

![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)
![Python](https://img.shields.io/badge/python-3.11-blue.svg)
![CI](https://github.com/fred-diaz-analytics/aisleiq/actions/workflows/pull-request.yml/badge.svg)

Pipeline de dados em arquitetura medalhão (bronze/silver/gold) no Databricks para KPIs de
execução de PDV (presença, ruptura, preço, MPDV, ponto extra, share de gôndola) e de
atendimento de promotores em campo. Construído como um **Databricks Asset Bundle**:
Lakeflow Declarative Pipeline (nome atual do antigo Delta Live Tables) para silver/gold,
orquestrada por um Job (bronze + trigger da pipeline).

Os dados são **100% sintéticos**, gerados de forma determinística por
[`data/lib_geracao.py`](data/lib_geracao.py). Sem PII, seguros para um repositório público.

> Documentação completa (arquitetura por camada, dicionário de dados) em [`docs/`](docs/index.md).
> Veja também a seção [Site de documentação](#site-de-documentação) abaixo.

## Sumário

- [Tech stack](#tech-stack)
- [Arquitetura](#arquitetura)
- [Estrutura do bundle](#estrutura-do-bundle)
- [Catálogos Unity Catalog](#catálogos-unity-catalog)
- [Como rodar](#como-rodar)
- [Testes](#testes)
- [KPIs (camada gold)](#kpis-camada-gold)
- [Dimensões (camada gold)](#dimensões-camada-gold)
- [Site de documentação](#site-de-documentação)
- [Licença](#licença)

## Tech stack

- **[Databricks](https://www.databricks.com/)**: Databricks Asset Bundle, Lakeflow Declarative
  Pipelines, Unity Catalog, Jobs, Delta Lake
- **[Supabase Storage](https://supabase.com/storage)**: object storage S3-compatible (origem dos
  arquivos que a bronze ingere)
- **Python 3.11**: gerador sintético, scripts de export/upload, testes
- **SQL**: toda a transformação silver/gold (Lakeflow Declarative Pipelines)
- **[MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/)**: site de documentação
- **pytest, ruff, yamllint**: testes e lint, rodando em CI (GitHub Actions)

## Arquitetura

```
data/lib_geracao.py ──► parquet local (data/execucao_pdv/, data/atendimento/)
        │  (job_diario.py --upload-supabase)
        ▼
Supabase Storage (S3-compatible)
        │  (Job: bronze_ingest.py, roda 2x — um por domínio)
        ▼
Bronze  (Delta Tables, catálogo.bronze)         — snapshot raw, 1 arquivo = 1 dia, idempotente
        │  (Lakeflow Declarative Pipeline)
        ▼
Silver  (Materialized Views, catálogo.silver)   — tipado, deduplicado, validado (EXPECT/DROP ROW)
        │
        ▼
Gold    (Materialized Views, catálogo.gold)     — 8 KPIs + 2 dimensões (dim_loja, dim_produto)
```

Além do fluxo diário (execução de PDV + atendimento), dois domínios de **dado mestre**
(`lojas`, `produtos`) rodam sob demanda, full-reload, fora do job/schedule diário. Ver
[`docs/arquitetura.md`](docs/arquitetura.md#dado-mestre-lojas-e-produtos).

- **Bronze roda como Job Task comum**, fora da Lakeflow Declarative Pipeline (decisão
  deliberada, ver [`bronze_ingest.py`](src/pipelines/trade_analytics/transformations/bronze/bronze_ingest.py)):
  um único notebook parametrizado (`prefix`/`file_regex`/`table_name` via `base_parameters`)
  roda duas vezes, uma por domínio (`execucao_pdv`, `atendimentos`). Ingestão incremental por
  watermark de `source_date`, com lookback configurável, escrita idempotente via
  `replaceWhere` e falha isolada por arquivo.
- **Silver e Gold são a Lakeflow Declarative Pipeline** (`resources/pipelines.trade_analytics.yml`),
  definida em SQL puro (`CREATE OR REFRESH MATERIALIZED VIEW ... EXPECT ...`) em
  [`src/pipelines/trade_analytics/transformations/{silver,gold}/`](src/pipelines/trade_analytics/transformations/).

## Estrutura do bundle

```
databricks.yml                  # bundle "trade_analytics" — targets dev/prod, variáveis
resources/
  jobs.trade_analytics.yml      # Jobs: trade_analytics (diário) + trade_analytics_lojas/_produtos (sob demanda)
  pipelines.trade_analytics.yml # Lakeflow Declarative Pipeline (silver + gold)
  schemas.yml                   # cria os schemas UC bronze/silver/gold
  volumes.yml                   # volume de staging bronze.raw_files
src/pipelines/trade_analytics/transformations/
  bronze/bronze_ingest.py           # notebook parametrizado (execucao_pdv/atendimentos, incremental)
  bronze/bronze_ingest_lojas.py     # dado mestre lojas, full-reload
  bronze/bronze_ingest_produtos.py  # dado mestre produtos, full-reload
  bronze/bronze_lib.py              # lógica pura (regex/data), testada offline
  silver/*.sql                      # execucao_pdv, atendimentos, lojas (5 MVs), produtos (3 MVs)
  gold/*.sql                        # 8 KPIs + dim_loja + dim_produto
data/
  lib_geracao.py                # gerador sintético determinístico (seed fixa)
  backfill_2026.py              # seed histórico (2026-01-01 a 2026-08-10)
  upload_backfill.py            # sobe o backfill histórico pro Supabase
  job_diario.py                 # entrypoint diário, modo catch-up
  export_dim_loja.py, export_dim_produto.py    # derivam os CSVs de dado mestre
  upload_dim_loja.py, upload_dim_produto.py    # sobem os CSVs de dado mestre pro Supabase
  execucao_pdv/, atendimento/   # parquet gerado, snapshot fixo até 2026-08-21 (ver nota abaixo)
tests/unit/                     # pytest — lógica pura de bronze_lib.py, sem cluster/rede
docs/                           # site de documentação (MkDocs + Material)
```

## Catálogos Unity Catalog

O bundle usa a variável `catalog` (`aisleiq_dev` em dev, `aisleiq_prod` em prod, ver
`targets.*.variables.catalog` em [`databricks.yml`](databricks.yml)) para criar os schemas
`bronze`/`silver`/`gold` e o volume `bronze.raw_files`. **O catálogo em si precisa já existir**
no metastore antes do deploy: o bundle não cria catálogos, só schemas dentro deles.

`dev` não usa `mode: development` de propósito: esse modo prefixaria os recursos (inclusive os
schemas UC) com `dev_<user>_`, quebrando a exigência de nomes exatos do projeto.

## Como rodar

### Pré-requisitos

- **Python 3.11+**
- **[Databricks CLI](https://docs.databricks.com/dev-tools/cli/index.html)** instalado e
  autenticado (`databricks auth login`) contra o seu workspace
- **Um catálogo Unity Catalog já criado** no seu metastore, para o target `dev` (e outro para
  `prod`, se for usar). Crie pela **UI**: Catalog Explorer → *Create Catalog*. Não há um
  comando de CLI confiável para esse passo em workspaces novos, então não tente automatizar
  isso via `databricks catalogs create`
- **Um projeto [Supabase](https://supabase.com/) (ou qualquer storage S3-compatible)**, de
  onde a bronze lê os arquivos gerados. No Supabase: crie um projeto, ative o *Storage*, e
  pegue o endpoint S3 e as credenciais em *Storage → Settings → S3 Connection*. O free tier do
  Supabase é suficiente para o volume deste projeto.

> ℹ️ O **Databricks Free Edition** (atual, diferente da antiga Community Edition) já suporta
> Unity Catalog, Jobs e Lakeflow Declarative Pipelines, suficiente para rodar este projeto
> sem custo.

`s3_endpoint` (usado nos comandos abaixo) não tem valor default de propósito. Nunca é
commitado; sempre via `--var="s3_endpoint=..."` ou pela variável de ambiente
`BUNDLE_VAR_s3_endpoint`.

### Passo a passo

```bash
# 1. Ambiente Python
python -m venv .venv
.venv\Scripts\activate        # Windows (Linux/Mac: source .venv/bin/activate)
pip install -r requirements-dev.txt

# 2. Credenciais do storage
cd data
cp ../.env.example .env       # preencha com o endpoint + credenciais S3 do seu Supabase

# 3. Gerar e subir os dados sintéticos (fatos + dado mestre)
python backfill_2026.py --out-dir .            # seed histórico, uma vez
python upload_backfill.py --out-dir .          # sobe o backfill pro Supabase
python export_dim_loja.py --out-dir . && python upload_dim_loja.py --out-dir .
python export_dim_produto.py --out-dir . && python upload_dim_produto.py --out-dir .
cd ..

# 4. Edite databricks.yml: troque <SEU_WORKSPACE> pelo host real do seu workspace
#    (targets.dev.workspace.host e targets.prod.workspace.host)

# 5. Validar
databricks bundle validate -t dev --var="s3_endpoint=https://<seu-projeto>.storage.supabase.co/storage/v1/s3"

# 6. Criar o secret scope com as credenciais S3 (nunca hardcoded no código/config)
databricks secrets create-scope supabase
databricks secrets put-secret supabase access_key_id
databricks secrets put-secret supabase secret_access_key

# 7. Deploy
databricks bundle deploy -t dev --var="s3_endpoint=https://<seu-projeto>.storage.supabase.co/storage/v1/s3"

# 8. Popular o dado mestre (uma vez, ou sempre que lojas/produtos mudarem) --
#    OBRIGATÓRIO antes do passo 9: a mesma Lakeflow Pipeline materializa as MVs
#    de lojas/produtos junto com execucao_pdv/atendimentos (mesmo glob
#    silver/**+gold/**), então sem esse passo o passo 9 falha ao tentar ler
#    bronze.lojas/bronze.produtos, que ainda não existiriam.
databricks bundle run trade_analytics_lojas -t dev --var="s3_endpoint=https://<seu-projeto>.storage.supabase.co/storage/v1/s3"
databricks bundle run trade_analytics_produtos -t dev --var="s3_endpoint=https://<seu-projeto>.storage.supabase.co/storage/v1/s3"

# 9. Rodar o job diário (bronze x2 + pipeline silver/gold)
databricks bundle run trade_analytics -t dev --var="s3_endpoint=https://<seu-projeto>.storage.supabase.co/storage/v1/s3"
```

### Operação contínua: catch-up diário

Depois do setup inicial acima, isto roda continuamente (não é um passo único):

`job_diario.py` roda em **modo catch-up**: sem `--data`, ele detecta sozinho o último dia já
gerado e preenche todo dia útil faltante até hoje (pulando fins de semana). Um único run
depois de vários dias parado cobre o buraco inteiro.

```bash
python data/job_diario.py --dominio todos --out-dir data --upload-supabase
```

Pensado para rodar via agendador local (Task Scheduler/cron) todo dia antes do primeiro
horário do Job Databricks.

> ℹ️ **Snapshot fixo de dados**: os parquet commitados em `data/execucao_pdv/` e
> `data/atendimento/` são um snapshot fixo até **21/08/2026**, pequeno, determinístico, sem
> PII, mantido pra o repo ficar pronto pra rodar sem precisar gerar nada antes. O catch-up
> diário continua rodando localmente e subindo pro Supabase normalmente, mas arquivos gerados
> depois dessa data **não** são commitados daqui em diante (o `.gitignore` só bloqueia
> datas novas/não rastreadas; não remove o que já está rastreado, então não precisa de
> manutenção). Rode `backfill_2026.py`/`job_diario.py` você mesmo se quiser dado sintético
> mais recente localmente.

## Testes

```bash
pytest tests/unit      # lógica pura de bronze_lib.py — sem cluster, sem rede, roda em qualquer CI
ruff check .
yamllint .
```

## KPIs (camada gold)

| Tabela | Grão | Descrição |
|---|---|---|
| `execucao_pdv_presenca` | loja/produto/dia | % de avaliações com produto presente na loja |
| `execucao_pdv_ruptura` | loja/produto/dia | % de avaliações com produto em ruptura (falta de estoque) |
| `execucao_pdv_preco` | loja/produto/dia | Preço praticado — médio, mínimo, máximo |
| `execucao_pdv_mpdv` | loja/produto/dia | % de avaliações com material de ponto de venda ativado |
| `execucao_pdv_ponto_extra` | loja/produto/dia | Total e média de pontos extras conquistados |
| `execucao_pdv_share_gondola` | loja/produto/dia | Share médio de gôndola |
| `atendimento_cumprimento_visita` | promotor/loja/dia | Taxa de visitas OK vs. NP (não pôde) vs. X (cancelada) |
| `atendimento_tempo_loja` | promotor/loja/dia | Tempo médio/total de permanência em loja |

## Dimensões (camada gold)

| Tabela | Grão | Descrição |
|---|---|---|
| `dim_loja` | 1 por loja | Rede, categoria, cidade, UF, região — join via `id_loja` no BI |
| `dim_produto` | 1 por produto | Marca, categoria, tamanho — join via `id_produto` no BI |

Nenhuma das 8 KPIs referencia essas dimensões por FK em SQL. O join acontece no modelo de BI.

Detalhamento completo de cada coluna em [`docs/dicionario.md`](docs/dicionario.md).

## Site de documentação

O conteúdo de [`docs/`](docs/) é publicado como site estático via
[MkDocs](https://www.mkdocs.org/) + [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/):

```bash
pip install mkdocs mkdocs-material   # já em requirements-dev.txt
mkdocs serve     # http://127.0.0.1:8000
mkdocs build     # gera site/ estático
```

## Licença

[MIT](LICENSE)
