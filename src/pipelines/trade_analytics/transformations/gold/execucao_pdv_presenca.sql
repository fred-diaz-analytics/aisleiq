-- Gold — execucao_pdv_presenca
-- % de avaliações em que o produto estava presente na loja, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca (
  -- sem ON VIOLATION DROP ROW de propósito: dropar uma linha de KPI já
  -- agregada esconderia o problema em vez de expor. Só registra a violação.
  CONSTRAINT pct_presenca_no_intervalo EXPECT (pct_presenca BETWEEN 0 AND 100)
)
COMMENT 'KPI de presença de produto em loja, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS total_avaliacoes,
  SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) AS total_presente,
  ROUND(100.0 * SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_presenca
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'PRESENCA' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
