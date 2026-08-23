-- Gold — execucao_pdv_preco
-- Preço praticado por produto em loja: média, mínimo e máximo, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_preco (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT preco_medio_positivo EXPECT (preco_medio > 0)
)
COMMENT 'KPI de preço praticado por produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS qtd_amostras,
  ROUND(AVG(resposta_preco), 2) AS preco_medio,
  MIN(resposta_preco) AS preco_min,
  MAX(resposta_preco) AS preco_max
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'PRECO' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
