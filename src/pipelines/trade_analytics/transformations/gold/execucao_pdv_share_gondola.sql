-- Gold — execucao_pdv_share_gondola
-- Share médio de gôndola por produto em loja, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT share_medio_no_intervalo EXPECT (share_medio BETWEEN 0 AND 100)
)
COMMENT 'KPI de share de gôndola por produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS qtd_amostras,
  ROUND(AVG(resposta_percentual), 2) AS share_medio
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'SHARE_GONDOLA' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
