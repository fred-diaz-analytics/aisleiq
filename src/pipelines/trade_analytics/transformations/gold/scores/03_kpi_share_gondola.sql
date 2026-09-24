-- Score de execução PDV — kpi_share_gondola
-- KPI 3/5 — Share de Gôndola — peso 15%.
-- Target: meta de share por marca x canal (gold.meta_share). Substitui o
-- antigo "share justo" = 100% / nº de marcas próprias da categoria, que
-- não tinha significado de negócio: marca pequena (share real 3-9%) nunca
-- chegava perto de 33-50% e a nota virava efeito do mix de marcas,
-- praticamente igual em toda loja.
-- Nota 100 ao atingir/superar a meta; abaixo disso, escala linear até 0.
-- Grão: (id_loja, dt_pesquisa, categoria_produto) — média simples entre
-- marcas/tamanhos da categoria.
-- JOIN visitas_completas: produto ausente não tem share (não entra aqui).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_share_gondola (
  CONSTRAINT avg_nota_share_no_intervalo EXPECT (avg_nota_share BETWEEN 0 AND 100)
)
COMMENT 'KPI de share de gôndola vs. meta de share por marca x canal, peso 15% do score.'
AS
WITH share_score AS (
  SELECT
    sg.id_loja,
    sg.dt_pesquisa,
    dp.categoria_produto,
    sg.share_medio,
    ms.meta_share_pct,
    ROUND(LEAST(100, 100.0 * sg.share_medio / ms.meta_share_pct), 2) AS nota_share
  FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola sg
  JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
    ON sg.id_loja = vc.id_loja
   AND sg.id_produto = vc.id_produto
   AND sg.dt_pesquisa = vc.dt_pesquisa
  JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
    ON sg.id_produto = dp.id_produto
  JOIN ${medallion_catalog}.${gold_schema}.dim_loja dl
    ON sg.id_loja = dl.id_loja
  JOIN ${medallion_catalog}.${gold_schema}.meta_share ms
    ON dp.marca = ms.marca
   AND dl.categoria_loja = ms.categoria_loja
)
SELECT
  id_loja,
  dt_pesquisa,
  categoria_produto,
  ROUND(AVG(nota_share), 2) AS avg_nota_share
FROM share_score
GROUP BY
  id_loja,
  dt_pesquisa,
  categoria_produto
