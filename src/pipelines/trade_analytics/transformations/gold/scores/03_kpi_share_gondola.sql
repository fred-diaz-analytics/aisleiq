-- Score de execução PDV — kpi_share_gondola
-- KPI 3/5 — Share de Gôndola — peso 15%.
-- Target = "share justo" por categoria = 100% / nº de marcas cadastradas
-- naquela categoria, contado direto do catálogo (dim_produto) — não
-- hardcoded, e não derivado da tabela de fato. Diferença deliberada em
-- relação ao protótipo local: contar DISTINCT marca em cima da fato
-- (execucao_pdv_share_gondola) subconta marca sem observação recente de
-- share; dim_produto reflete o catálogo real, independente de ter sido
-- observada essa semana.
-- Nota 100 ao atingir/superar o share justo; abaixo disso, escala linear
-- até 0.
-- Grão: (id_loja, dt_pesquisa, categoria_produto) — média simples entre
-- marcas/tamanhos da categoria.
-- JOIN visitas_completas: só entra quem tem os 4 indicadores obrigatórios.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_share_gondola (
  CONSTRAINT avg_nota_share_no_intervalo EXPECT (avg_nota_share BETWEEN 0 AND 100)
)
COMMENT 'KPI de share de gôndola vs. share justo do catálogo, peso 15% do score.'
AS
WITH marcas_por_categoria AS (
  SELECT
    categoria_produto,
    COUNT(DISTINCT marca) AS n_marcas
  FROM ${medallion_catalog}.${gold_schema}.dim_produto
  GROUP BY categoria_produto
),
share_score AS (
  SELECT
    sg.id_loja,
    sg.dt_pesquisa,
    dp.categoria_produto,
    sg.share_medio,
    ROUND(100.0 / mpc.n_marcas, 2) AS share_justo,
    ROUND(LEAST(100, 100.0 * sg.share_medio / (100.0 / mpc.n_marcas)), 2) AS nota_share
  FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola sg
  JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
    ON sg.id_loja = vc.id_loja
   AND sg.id_produto = vc.id_produto
   AND sg.dt_pesquisa = vc.dt_pesquisa
  JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
    ON sg.id_produto = dp.id_produto
  JOIN marcas_por_categoria mpc
    ON dp.categoria_produto = mpc.categoria_produto
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
