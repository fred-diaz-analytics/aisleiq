-- Gold — execucao_pdv_preco
-- Preço praticado por produto em loja, por loja/produto/dia. Grão da
-- pesquisa é uma resposta por combinação (loja, produto, dia) — garantido
-- pelo dedup_sync de silver.execucao_pdv (ROW_NUMBER particionado por
-- loja/produto/indicador/usuário/dia), confirmado empiricamente em
-- produção (ver commit). Exclui outlier estatístico via flag_outlier,
-- calculado em silver.execucao_pdv_preco_stats.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_preco (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT preco_observado_positivo EXPECT (preco_observado > 0)
)
COMMENT 'KPI de preço praticado por produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  MAX(resposta_preco) AS preco_observado
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv_preco_stats
WHERE flag_outlier = false
GROUP BY id_loja, id_produto, dt_pesquisa
