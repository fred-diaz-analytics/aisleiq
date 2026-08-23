# AisleIQ

Pipeline de dados em arquitetura medalhão (bronze/silver/gold) no Databricks, construído como
**Databricks Asset Bundle**, para KPIs de execução de PDV e de atendimento de promotores em
campo.

Os dados são **100% sintéticos**, gerados de forma determinística e sem PII. Isso torna o
projeto seguro para ser público e serve como referência de arquitetura completa: geração de
dados → storage S3-compatible → ingestão incremental → transformação declarativa → KPIs.

!!! note "Sobre o stack usado"
    Este projeto foi construído com **Databricks** (compute/orquestração/Lakeflow Declarative
    Pipelines) e **Power BI** (dashboards), ambos em seus free tiers. Nenhum dos dois é
    open-source, mas a arquitetura em si (medalhão bronze/silver/gold, ingestão incremental,
    transformação declarativa, KPIs agregados) é replicável integralmente com ferramentas
    100% open-source e self-hostable, por exemplo:

    - **Transformação**: [dbt-core](https://github.com/dbt-labs/dbt-core) no lugar do Lakeflow
      Declarative Pipelines.
    - **Warehouse**: [PostgreSQL](https://www.postgresql.org/) self-hosted (ou
      [DuckDB](https://duckdb.org/) para volumes menores) no lugar do Unity Catalog/Delta Lake.
      [Supabase](https://supabase.com/) também funciona bem aqui: a parte de banco (Postgres)
      é open-source, mas o produto hospedado como um todo não é 100% open-source nem
      gratuito em escala.
    - **Storage S3-compatible**: [MinIO](https://min.io/) self-hosted no lugar do Supabase
      Storage.
    - **Orquestração**: [Apache Airflow](https://airflow.apache.org/) ou
      [Dagster](https://dagster.io/) no lugar dos Jobs do Databricks.
    - **Dashboards**: [Streamlit](https://streamlit.io/) ou [Metabase](https://www.metabase.com/)
      no lugar do Power BI.

## Por onde começar

- **[Arquitetura](arquitetura.md)**: como as camadas bronze/silver/gold se conectam, a
  estrutura do bundle e como rodar o deploy.
- **[Execução de PDV](execucao-pdv.md)**: as 6 KPIs de presença, ruptura, preço, MPDV, ponto
  extra e share de gôndola.
- **[Atendimento](atendimento.md)**: as 2 KPIs de cumprimento de visita e tempo em loja dos
  promotores.
- **[Pipeline diário](pipeline-diario.md)**: o gerador sintético e o catch-up automático que
  alimentam o pipeline com dados novos todo dia.
- **[Dicionário de dados](dicionario.md)**: todas as colunas de todas as tabelas, camada por
  camada.

## Visão geral

```
data/lib_geracao.py ──► parquet local ──► Supabase Storage (S3) ──► Bronze ──► Silver ──► Gold
```

| Camada | Tecnologia | Papel |
|---|---|---|
| Bronze | Job Task (notebook parametrizado) | Ingestão incremental, watermark por dia, idempotente |
| Silver | Lakeflow Declarative Pipeline (SQL) | Tipagem, validação (`EXPECT`), deduplicação |
| Gold | Lakeflow Declarative Pipeline (SQL) | 8 KPIs agregados + `dim_loja`/`dim_produto` (achatadas, join no BI) |

Dois domínios de **dado mestre** (lojas, produtos) rodam à parte: full-reload, sob demanda,
fora do fluxo diário acima. Ver [Arquitetura](arquitetura.md#dado-mestre-lojas-e-produtos).

Código-fonte completo no [README do repositório](../README.md).
