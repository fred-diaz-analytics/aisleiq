-- Score de execução PDV — kpi_preco
-- KPI 2/5 — Preço — peso 20%.
-- Target: preço sugerido por SKU x canal (gold.meta_preco), com a banda de
-- tolerância vinda da própria meta. Substitui a antiga mediana móvel de
-- 30 dias do preço OBSERVADO, que era auto-referente (se o mercado todo
-- deriva 10% abaixo, a aderência continuava 100) e deixava todo SKU sem
-- nota nos primeiros 30 dias.
--
-- Curva assimétrica (espelhada em Python por nota_preco() em
-- data/lib_geracao.py, usada no gabarito dos efeitos plantados):
--   dentro da banda (padrão -3% a +5%): nota 100
--   abaixo da banda: queda íngreme (quadrática), ~0 na linha vermelha -18%
--   acima da banda: queda suave, só chegando a um piso baixo perto de +35%
--
-- Grão: (id_loja, dt_pesquisa, categoria_produto) — média simples entre
-- marcas/tamanhos da categoria. JOIN visitas_completas: produto ausente
-- não tem preço (não entra aqui; a falha dele é contada na disponibilidade).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_preco (
  CONSTRAINT avg_nota_preco_no_intervalo EXPECT (avg_nota_preco BETWEEN 0 AND 100)
)
COMMENT 'KPI de aderência de preço ao preço sugerido por canal, peso 20% do score.'
AS
WITH preco_base AS (
  SELECT
    p.id_loja,
    p.id_produto,
    dp.categoria_produto,
    p.dt_pesquisa,
    (p.preco_observado - mp.preco_sugerido) / mp.preco_sugerido AS desvio_pct,
    mp.banda_min_pct / 100 AS banda_min,
    mp.banda_max_pct / 100 AS banda_max
  FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_preco p
  JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
    ON p.id_loja = vc.id_loja
   AND p.id_produto = vc.id_produto
   AND p.dt_pesquisa = vc.dt_pesquisa
  JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
    ON p.id_produto = dp.id_produto
  JOIN ${medallion_catalog}.${gold_schema}.dim_loja dl
    ON p.id_loja = dl.id_loja
  JOIN ${medallion_catalog}.${gold_schema}.meta_preco mp
    ON p.id_produto = mp.id_produto
   AND dl.categoria_loja = mp.categoria_loja
),
preco_score AS (
  SELECT
    id_loja,
    id_produto,
    categoria_produto,
    dt_pesquisa,
    desvio_pct,
    ROUND(
      GREATEST(
        0.01,
        CASE
          WHEN desvio_pct <= -0.18 THEN 0.01
          WHEN desvio_pct < banda_min THEN
            1 - POWER((ABS(desvio_pct) - ABS(banda_min)) / (0.18 - ABS(banda_min)), 2)
          WHEN desvio_pct <= banda_max THEN 1
          ELSE 1 - 10 * POWER(desvio_pct - banda_max, 2)
        END
      ) * 100,
    2) AS nota_preco
  FROM preco_base
)
SELECT
  id_loja,
  dt_pesquisa,
  categoria_produto,
  ROUND(AVG(nota_preco), 2) AS avg_nota_preco,
  ROUND(100 * AVG(desvio_pct), 2) AS avg_desvio_preco_pct
FROM preco_score
GROUP BY
  id_loja,
  dt_pesquisa,
  categoria_produto
