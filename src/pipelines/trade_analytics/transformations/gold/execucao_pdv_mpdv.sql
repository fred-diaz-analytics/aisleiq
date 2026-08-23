-- Gold — execucao_pdv_mpdv
-- % de avaliações em que havia material de ponto de venda (MPDV) ativado, por loja/produto/dia.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.execucao_pdv_mpdv (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT pct_material_ativado_no_intervalo EXPECT (pct_material_ativado BETWEEN 0 AND 100)
)
COMMENT 'KPI de material de ponto de venda (MPDV) ativado, por loja/produto/dia.'
AS
SELECT
  id_loja,
  id_produto,
  dt_pesquisa,
  COUNT(*) AS total_avaliacoes,
  SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) AS total_material_ativado,
  ROUND(100.0 * SUM(CASE WHEN resposta_bool THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_material_ativado
FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
WHERE indicador = 'MPDV' AND resposta_valida
GROUP BY id_loja, id_produto, dt_pesquisa
