# Arquitetura

## Descrição

O AisleIQ é um **Databricks Asset Bundle** (nome interno do bundle: `trade_analytics`) que
implementa arquitetura medalhão (bronze, silver, gold) para dados de execução de PDV
(presença, ruptura, preço, MPDV, ponto extra, share de gôndola) e de atendimento de
promotores (visitas a loja).

## Objetivos

- Ingerir de forma incremental e idempotente arquivos Parquet publicados diariamente em um
  bucket S3-compatible.
- Tipar, validar e deduplicar os dados brutos na camada silver, com regras de qualidade
  explícitas (`EXPECT` do Lakeflow Declarative Pipelines).
- Modelar 8 KPIs prontos para consumo em BI na camada gold.
- Ser reproduzível do zero: catálogo Unity Catalog + Databricks CLI autenticado são os únicos
  pré-requisitos externos.

## Fluxo de Origem dos Dados

**Extração.** `data/lib_geracao.py` gera Parquet sintético localmente, determinístico com seed
fixa (ver [Pipeline diário](pipeline-diario.md)). `job_diario.py --upload-supabase` sobe os
arquivos para um bucket Supabase Storage (S3-compatible), em `trade_analytics/execucao_pdv/` e
`trade_analytics/atendimento/`.

**Bronze.** O Job `trade_analytics`
([`resources/jobs.trade_analytics.yml`](../resources/jobs.trade_analytics.yml)) roda o notebook
[`bronze_ingest.py`](../src/pipelines/trade_analytics/transformations/bronze/bronze_ingest.py)
duas vezes, uma por domínio, via `base_parameters` diferentes. Cada execução:

1. Lista candidatos no bucket que batem no `file_regex` do domínio e têm `source_date` maior
   que o watermark atual, menos um lookback de segurança (default 3 dias).
2. Baixa cada arquivo para um Volume UC de staging (`bronze.raw_files`).
3. Grava na tabela Delta bronze via `replaceWhere`: substituição atômica por `source_file`,
   idempotente, sem duplicar em reprocessamentos.
4. Isola falhas por arquivo. Um Parquet corrompido não derruba o restante da carga.

**Silver e Gold.** A Lakeflow Declarative Pipeline `silver_gold`
([`resources/pipelines.trade_analytics.yml`](../resources/pipelines.trade_analytics.yml)) lê a
bronze e materializa:
- **Silver** ([`silver/*.sql`](../src/pipelines/trade_analytics/transformations/silver/)): tipagem
  de datas/horas, limpeza de campos texto-livre, deduplicação de syncs duplicados do app de
  campo e de disputas loja/dia, validação geoloc de check-in/check-out.
- **Gold** ([`gold/*.sql`](../src/pipelines/trade_analytics/transformations/gold/)): agregação
  por loja/produto/dia (execução de PDV) ou promotor/loja/dia (atendimento).

Tudo materializado como Delta Tables/Materialized Views em Unity Catalog, sob o catálogo
`aisleiq_dev` ou `aisleiq_prod` conforme o target do bundle.

## Dado mestre (lojas e produtos)

Além do fluxo diário acima (fatos), dois domínios de **dado mestre** seguem um padrão
diferente: full-reload, sob demanda, fora do job/schedule diário.

- **`lojas`**: 5 CSVs (`estados`, `cidades`, `categorias_loja`, `redes`, `lojas`), exportados de
  `dclientes.csv` via [`export_dim_loja.py`](../data/export_dim_loja.py) →
  [`bronze_ingest_lojas.py`](../src/pipelines/trade_analytics/transformations/bronze/bronze_ingest_lojas.py)
  (`CREATE OR REPLACE`, sem watermark) → 5 MVs silver snowflake → `gold.dim_loja` (achatada).
- **`produtos`**: 2 CSVs (`categorias`, `produtos`), gerados direto do catálogo do gerador via
  [`export_dim_produto.py`](../data/export_dim_produto.py) →
  [`bronze_ingest_produtos.py`](../src/pipelines/trade_analytics/transformations/bronze/bronze_ingest_produtos.py)
  → 3 MVs silver (`categorias`, `marcas`, `produtos`; `marcas` sem bronze própria, derivada por
  `SELECT DISTINCT`) → `gold.dim_produto` (achatada).

Nenhuma das duas tem FK em nenhuma gold table de KPI: o join acontece no modelo de BI, via
`id_loja`/`id_produto`. Rodam como Jobs separados (`trade_analytics_lojas`,
`trade_analytics_produtos`), sem `schedule`, disparados manualmente quando o cadastro muda.

## Especificação Técnica

| Recurso | Definição | Observação |
|---|---|---|
| Bundle | [`databricks.yml`](../databricks.yml) | targets `dev` (default) e `prod`, variáveis `catalog`/`s3_endpoint` |
| Job diário | [`resources/jobs.trade_analytics.yml`](../resources/jobs.trade_analytics.yml) | cron `0 0 7,13 * * ?` (America/Sao_Paulo), pausado em dev |
| Jobs de dado mestre | mesmo arquivo, resources `trade_analytics_lojas`/`trade_analytics_produtos` | sem `schedule`, sob demanda |
| Pipeline | [`resources/pipelines.trade_analytics.yml`](../resources/pipelines.trade_analytics.yml) | Lakeflow Declarative Pipeline serverless |
| Schemas | [`resources/schemas.yml`](../resources/schemas.yml) | cria `bronze`/`silver`/`gold` — catálogo precisa já existir |
| Volume | [`resources/volumes.yml`](../resources/volumes.yml) | `bronze.raw_files`, staging de download |
| Credenciais S3 | Databricks secret scope `supabase` | keys `access_key_id`/`secret_access_key`, nunca hardcoded |

`dev` não usa `mode: development` de propósito: esse modo prefixaria os schemas UC com
`dev_<user>_`, quebrando a exigência de nomes exatos (`bronze`/`silver`/`gold`) do projeto.

Colunas de todas as tabelas em [Dicionário de dados](dicionario.md).

## Casos de Uso

- Time comercial/trade marketing acompanhando presença, ruptura e preço por produto/loja ao
  longo do tempo.
- Gestão de campo medindo cumprimento de visita e tempo em loja por promotor.
- BI/dashboards consumindo as 8 tabelas gold direto, já agregadas por dia.

## Como rodar

```bash
databricks bundle validate -t dev --var="s3_endpoint=..."
databricks bundle deploy -t dev --var="s3_endpoint=..."
databricks bundle run trade_analytics -t dev --var="s3_endpoint=..."
```

Ver [README](../README.md#como-rodar) para o passo a passo completo, incluindo o setup do
secret scope de credenciais S3.
