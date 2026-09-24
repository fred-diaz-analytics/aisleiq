-- Silver — domínio `metas` (metas comerciais, dado mestre)
-- Tipado e deduplicado por chave, mesmo padrão de silver/produtos.sql.
-- Bronze já é full-reload (sem duplicidade entre execuções); dedup por
-- chave aqui é defensivo, documentando o contrato. Uma versão vigente por
-- chave (vigencia_inicio é informativa — sem histórico de versões ainda).

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.preco_sugerido (
  CONSTRAINT chave_presente EXPECT (id_produto IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT preco_sugerido_positivo EXPECT (preco_sugerido > 0) ON VIOLATION DROP ROW,
  CONSTRAINT banda_coerente EXPECT (banda_min_pct < 0 AND banda_max_pct > 0)
)
COMMENT 'Preço sugerido (RRP) por produto x canal (categoria_loja), com banda de tolerância em %.'
AS
WITH ranked AS (
  SELECT
    CAST(id_produto AS INT) AS id_produto,
    upper(trim(categoria_loja)) AS categoria_loja,
    CAST(preco_sugerido AS DECIMAL(10, 2)) AS preco_sugerido,
    CAST(banda_min_pct AS DECIMAL(5, 2)) AS banda_min_pct,
    CAST(banda_max_pct AS DECIMAL(5, 2)) AS banda_max_pct,
    CAST(vigencia_inicio AS DATE) AS vigencia_inicio,
    ROW_NUMBER() OVER (PARTITION BY id_produto, categoria_loja ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.preco_sugerido
)
SELECT id_produto, categoria_loja, preco_sugerido, banda_min_pct, banda_max_pct, vigencia_inicio
FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.sku_prioridade (
  CONSTRAINT chave_presente EXPECT (id_produto IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT giro_positivo EXPECT (giro_semanal_un > 0)
)
COMMENT 'Giro semanal esperado (unidades) e flag must-have por produto x canal.'
AS
WITH ranked AS (
  SELECT
    CAST(id_produto AS INT) AS id_produto,
    upper(trim(categoria_loja)) AS categoria_loja,
    CAST(giro_semanal_un AS DECIMAL(10, 1)) AS giro_semanal_un,
    CAST(must_have AS BOOLEAN) AS must_have,
    ROW_NUMBER() OVER (PARTITION BY id_produto, categoria_loja ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.sku_prioridade
)
SELECT id_produto, categoria_loja, giro_semanal_un, must_have
FROM ranked WHERE rn = 1;

CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.meta_share (
  CONSTRAINT chave_presente EXPECT (id_marca IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT meta_no_intervalo EXPECT (meta_share_pct > 0 AND meta_share_pct <= 100) ON VIOLATION DROP ROW
)
COMMENT 'Meta de share de gôndola (%) por marca x canal.'
AS
WITH ranked AS (
  SELECT
    CAST(id_marca AS INT) AS id_marca,
    upper(trim(categoria_loja)) AS categoria_loja,
    CAST(meta_share_pct AS DECIMAL(5, 2)) AS meta_share_pct,
    ROW_NUMBER() OVER (PARTITION BY id_marca, categoria_loja ORDER BY ingested_at DESC) AS rn
  FROM ${medallion_catalog}.${bronze_schema}.meta_share
)
SELECT id_marca, categoria_loja, meta_share_pct
FROM ranked WHERE rn = 1;
