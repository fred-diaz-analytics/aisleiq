-- Score de execução PDV — kpi_valor_em_risco
-- Não pontua: traduz falha de disponibilidade em R$. Pra cada
-- (loja, dia, categoria), soma o valor semanal (giro esperado x preço
-- sugerido, gold.sku_prioridade) dos SKUs indisponíveis na visita —
-- ausentes (deslistados) ou em ruptura. É a régua de priorização: onde a
-- gôndola errada custa mais, não só onde a nota é menor.
-- Proxy sem sell-out: assume que SKU indisponível perde o giro esperado
-- inteiro até ser corrigido (não modela substituição pelo shopper).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_valor_em_risco (
  CONSTRAINT valor_em_risco_nao_negativo EXPECT (valor_em_risco_semanal >= 0)
)
COMMENT 'R$/semana em risco por SKUs indisponíveis (ausentes ou em ruptura), por loja/dia/categoria.'
AS
WITH sku_visita AS (
  SELECT
    vc.id_loja,
    vc.dt_pesquisa,
    dp.categoria_produto,
    sp.must_have,
    sp.valor_semanal,
    vc.presente AND COALESCE(rp.total_ruptura, 0) = 0 AS disponivel
  FROM ${medallion_catalog}.${gold_schema}.visitas_completas vc
  JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
    ON vc.id_produto = dp.id_produto
  JOIN ${medallion_catalog}.${gold_schema}.dim_loja dl
    ON vc.id_loja = dl.id_loja
  JOIN ${medallion_catalog}.${gold_schema}.sku_prioridade sp
    ON vc.id_produto = sp.id_produto
   AND dl.categoria_loja = sp.categoria_loja
  LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura rp
    ON vc.id_loja = rp.id_loja
   AND vc.id_produto = rp.id_produto
   AND vc.dt_pesquisa = rp.dt_pesquisa
)
SELECT
  id_loja,
  dt_pesquisa,
  categoria_produto,
  COUNT(*) AS skus_avaliados,
  COUNT(*) FILTER (WHERE NOT disponivel) AS skus_indisponiveis,
  COUNT(*) FILTER (WHERE NOT disponivel AND must_have) AS must_have_indisponiveis,
  ROUND(SUM(CASE WHEN NOT disponivel THEN valor_semanal ELSE 0 END), 2) AS valor_em_risco_semanal
FROM sku_visita
GROUP BY
  id_loja,
  dt_pesquisa,
  categoria_produto
