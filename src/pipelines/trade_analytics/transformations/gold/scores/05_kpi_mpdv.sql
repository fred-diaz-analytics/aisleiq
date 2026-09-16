-- Score de execução PDV — kpi_mpdv
-- KPI 5/5 — MPDV (material de ponto de venda) — peso 5%.
-- Binário — SIM = 100, NÃO = 0. execucao_pdv_mpdv já expõe
-- pct_material_ativado como a fração de SIM entre respostas válidas, na
-- grão (id_loja, id_produto, dt_pesquisa) — aqui só rola pra cima até
-- (id_loja, dt_pesquisa, categoria_produto).
-- Grão: (id_loja, dt_pesquisa, categoria_produto). categoria_produto vem
-- de dim_produto.
-- JOIN visitas_completas: MPDV é opcional em si (não faz parte do gate
-- de completude), mas cai junto se a visita for incompleta nos 4
-- obrigatórios: fica fora do score mesmo tendo sido respondido.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_mpdv (
  CONSTRAINT avg_nota_mpdv_no_intervalo EXPECT (avg_nota_mpdv BETWEEN 0 AND 100)
)
COMMENT 'KPI de material de ponto de venda (MPDV) ativado, peso 5% do score.'
AS
SELECT
  m.id_loja,
  m.dt_pesquisa,
  dp.categoria_produto,
  ROUND(AVG(m.pct_material_ativado), 2) AS avg_nota_mpdv
FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_mpdv m
JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
  ON m.id_loja = vc.id_loja
 AND m.id_produto = vc.id_produto
 AND m.dt_pesquisa = vc.dt_pesquisa
JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
  ON m.id_produto = dp.id_produto
GROUP BY
  m.id_loja,
  m.dt_pesquisa,
  dp.categoria_produto
