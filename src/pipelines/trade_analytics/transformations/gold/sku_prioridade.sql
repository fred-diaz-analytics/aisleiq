-- Gold — sku_prioridade
-- Regra de negócio: importância de cada SKU por canal. valor_semanal
-- (giro esperado x preço sugerido, R$/semana) é o peso do SKU na
-- disponibilidade efetiva (scores/01) e a base do R$ em risco (scores/08)
-- — ruptura do carro-chefe pesa mais que ruptura de cauda.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.sku_prioridade (
  CONSTRAINT chave_presente EXPECT (id_produto IS NOT NULL AND categoria_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valor_semanal_positivo EXPECT (valor_semanal > 0)
)
COMMENT 'Prioridade de SKU por canal: giro semanal esperado, must-have e valor semanal (R$).'
AS
SELECT
  sp.id_produto,
  sp.categoria_loja,
  sp.giro_semanal_un,
  sp.must_have,
  ROUND(sp.giro_semanal_un * mp.preco_sugerido, 2) AS valor_semanal
FROM ${medallion_catalog}.${silver_schema}.sku_prioridade sp
JOIN ${medallion_catalog}.${silver_schema}.preco_sugerido mp
  ON sp.id_produto = mp.id_produto
 AND sp.categoria_loja = mp.categoria_loja
