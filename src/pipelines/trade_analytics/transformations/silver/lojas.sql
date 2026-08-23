-- Silver — domínio `lojas` (dado mestre)
-- Snowflake normalizado (5 tabelas), espelhando o que um sistema de
-- cadastro real exporia. Bronze já é full-reload (sem duplicidade entre
-- execuções); dedup por chave aqui é defensivo, documentando o contrato,
-- não porque tenha sujeira real pra tratar hoje.

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.estados (
  CONSTRAINT uf_presente EXPECT (uf IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Estados (UF), com região — dado mestre, tipado e deduplicado.'
AS
WITH ranked AS (
  SELECT
    uf, nome_estado, regiao,
    ROW_NUMBER() OVER (PARTITION BY uf ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.estados
)
SELECT uf, nome_estado, regiao FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.cidades (
  CONSTRAINT id_cidade_presente EXPECT (id_cidade IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Cidades, com UF — dado mestre, tipado e deduplicado.'
AS
WITH ranked AS (
  SELECT
    id_cidade, cidade, uf,
    ROW_NUMBER() OVER (PARTITION BY id_cidade ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.cidades
)
SELECT id_cidade, cidade, uf FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.categorias_loja (
  CONSTRAINT id_categoria_loja_presente EXPECT (id_categoria_loja IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Categorias de loja (VAREJO/ATACADO/ATACAREJO) — dado mestre.'
AS
WITH ranked AS (
  SELECT
    id_categoria_loja, categoria_loja,
    ROW_NUMBER() OVER (PARTITION BY id_categoria_loja ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.categorias_loja
)
SELECT id_categoria_loja, categoria_loja FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.redes (
  CONSTRAINT id_rede_presente EXPECT (id_rede IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Redes/bandeiras de loja — dado mestre.'
AS
WITH ranked AS (
  SELECT
    id_rede, nome_rede,
    ROW_NUMBER() OVER (PARTITION BY id_rede ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.redes
)
SELECT id_rede, nome_rede FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.lojas (
  CONSTRAINT id_loja_presente EXPECT (id_loja IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Lojas (dado mestre) — id_cidade/id_categoria_loja/id_rede como FK, ainda snowflake.'
AS
WITH ranked AS (
  SELECT
    id_loja, nome_fantasia, endereco, id_cidade, id_categoria_loja, id_rede,
    ROW_NUMBER() OVER (PARTITION BY id_loja ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.lojas
)
SELECT id_loja, nome_fantasia, endereco, id_cidade, id_categoria_loja, id_rede
FROM ranked WHERE rn = 1;
