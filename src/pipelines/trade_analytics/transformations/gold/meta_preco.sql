-- Gold — meta_preco
-- Regra/meta de negócio (não fato, não dimensão): preço sugerido por
-- produto x canal (categoria_loja) e a banda de tolerância. Consumida por
-- scores/02_kpi_preco (aderência de preço) e scores/08 (R$ em risco).
-- Join com loja é por categoria_loja via dim_loja.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.meta_preco (
  CONSTRAINT chave_presente EXPECT (id_produto IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Meta de preço: preço sugerido por produto x canal, com banda de tolerância (%).'
AS
SELECT id_produto, categoria_loja, preco_sugerido, banda_min_pct, banda_max_pct, vigencia_inicio
FROM ${medallion_catalog}.${silver_schema}.preco_sugerido
