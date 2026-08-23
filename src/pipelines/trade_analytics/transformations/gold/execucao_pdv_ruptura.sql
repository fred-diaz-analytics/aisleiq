-- Gold — execucao_pdv_ruptura
-- % de avaliações em que o produto estava em ruptura, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura (
  -- sem ON VIOLATION DROP ROW: uma linha de KPI errada deve aparecer e ser
  -- investigada, não desaparecer silenciosamente.
  CONSTRAINT pct_ruptura_no_intervalo EXPECT (pct_ruptura BETWEEN 0 AND 100)
)
COMMENT 'KPI de ruptura de produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS total_avaliacoes,
  SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) AS total_ruptura,
  ROUND(100.0 * SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_ruptura
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'RUPTURA' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
