-- Silver — domínio `produtos` (dado mestre)
-- Snowflake normalizado, espelhando o mesmo padrão do domínio `lojas`.
-- `marca` não tem bronze própria (nunca teve vida própria como cadastro no
-- sistema simulado, só é atributo de produto): silver.marcas é derivada
-- via SELECT DISTINCT de bronze.produtos, não de uma tabela bronze própria.
-- Bronze já é full-reload (sem duplicidade entre execuções); dedup por
-- chave aqui é defensivo, documentando o contrato.

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.categorias (
  CONSTRAINT id_categoria_presente EXPECT (id_categoria IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Categorias de produto — dado mestre, tipado e deduplicado.'
AS
WITH ranked AS (
  SELECT
    id_categoria, categoria_produto,
    ROW_NUMBER() OVER (PARTITION BY id_categoria ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.categorias
)
SELECT id_categoria, categoria_produto FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.marcas (
  CONSTRAINT id_marca_presente EXPECT (id_marca IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Marcas — derivada por SELECT DISTINCT de bronze.produtos, sem bronze própria (marca é atributo de produto, não cadastro à parte).'
AS
SELECT DISTINCT id_marca, marca
FROM ${medallion_catalog}.${bronze_schema}.produtos;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.produtos (
  CONSTRAINT id_produto_presente EXPECT (id_produto IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Produtos (dado mestre) — id_marca/id_categoria como FK, ainda snowflake.'
AS
WITH ranked AS (
  SELECT
    id_produto, produto, tamanho, id_marca, id_categoria,
    ROW_NUMBER() OVER (PARTITION BY id_produto ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.produtos
)
SELECT id_produto, produto, tamanho, id_marca, id_categoria
FROM ranked WHERE rn = 1;
