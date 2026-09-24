-- Gold — meta_share
-- Regra de negócio: meta de share de gôndola (%) por marca x canal.
-- Substitui o antigo "share justo" = 100% / nº de marcas próprias da
-- categoria, que punia marca pequena por ser pequena. Marca achatada pelo
-- nome (join com dim_produto é por marca, mesmo padrão star da gold).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.meta_share (
  CONSTRAINT chave_presente EXPECT (marca IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Meta de share de gôndola (%) por marca x canal.'
AS
SELECT
  ms.id_marca,
  m.marca,
  ms.categoria_loja,
  ms.meta_share_pct
FROM ${medallion_catalog}.${silver_schema}.meta_share ms
JOIN ${medallion_catalog}.${silver_schema}.marcas m
  ON ms.id_marca = m.id_marca
