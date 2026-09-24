-- Score de execução PDV — kpi_disponibilidade_efetiva
-- KPI 1/5 — Disponibilidade Efetiva (OSA) — peso 55%.
-- Por SKU-visita primeiro: OSA = presença x (1 - ruptura), 0-100. Produto
-- ausente (presença = NÃO) entra com OSA = 0 — é a pior falha de
-- disponibilidade e antes sumia do score (ver 00_visitas_completas).
-- Só depois agrega pra (id_loja, dt_pesquisa, categoria_produto), média
-- ponderada pelo valor semanal do SKU no canal da loja (giro x preço
-- sugerido, gold.sku_prioridade): ruptura do carro-chefe pesa mais que
-- ruptura de cauda. Antes era produto de médias simples
-- (AVG(presença) x AVG(1 - ruptura)), que não é OSA e contava duas vezes.
-- osa_must_have: OSA simples só dos SKUs must-have — base do "Perfect
-- Store" (loja com must-have faltando não é perfeita, seja qual for a nota).
-- categoria_produto vem de dim_produto e categoria_loja de dim_loja: as
-- gold tables de fato não carregam atributo de dimensão.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_disponibilidade_efetiva (
  CONSTRAINT disponibilidade_efetiva_no_intervalo EXPECT (disponibilidade_efetiva BETWEEN 0 AND 100)
)
COMMENT 'KPI de disponibilidade efetiva (OSA por SKU, ponderada por valor semanal), peso 55% do score.'
AS
WITH osa_sku AS (
  SELECT
    vc.id_loja,
    vc.id_produto,
    vc.dt_pesquisa,
    dp.categoria_produto,
    pr.pct_presenca,
    rp.pct_ruptura,
    pr.pct_presenca * (100 - COALESCE(rp.pct_ruptura, 0)) / 100 AS osa,
    sp.valor_semanal AS peso,
    sp.must_have
  FROM ${medallion_catalog}.${gold_schema}.visitas_completas vc
  JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca pr
    ON vc.id_loja = pr.id_loja
   AND vc.id_produto = pr.id_produto
   AND vc.dt_pesquisa = pr.dt_pesquisa
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
  ROUND(AVG(pct_presenca), 2) AS avg_disp,
  -- só sobre SKUs presentes (ausente não tem resposta de ruptura)
  ROUND(100 - AVG(pct_ruptura), 2) AS avg_shelf_disp,
  ROUND(SUM(osa * peso) / SUM(peso), 2) AS disponibilidade_efetiva,
  ROUND(AVG(CASE WHEN must_have THEN osa END), 2) AS osa_must_have
FROM osa_sku
GROUP BY
  id_loja,
  dt_pesquisa,
  categoria_produto
