-- Gold — execucao_pdv_ponto_extra
-- Total e média de pontos extras conquistados por produto em loja, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_ponto_extra (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT ponto_extra_medio_nao_negativo EXPECT (ponto_extra_medio >= 0)
)
COMMENT 'KPI de pontos extras por produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS qtd_amostras_validas,
  SUM(resposta_numero) AS ponto_extra_total,
  ROUND(AVG(resposta_numero), 2) AS ponto_extra_medio
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'PONTO_EXTRA' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
