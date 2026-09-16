-- Score de execução PDV — kpi_preco
-- KPI 2/5 — Preço — peso 20%.
-- Target: mediana móvel de 30 dias por SKU (não preço-alvo fixo — não
-- existe nesse projeto). Mediana absorve o erro de "dedo gordo" (preço
-- digitado ~10x maior) muito melhor que média — mesmo motivo pelo qual
-- execucao_pdv_preco_stats usa mediana/MAD pra flagar outlier.
--
-- Curva assimétrica:
--   banda de tolerância: -3% a +5% -> nota 100
--   abaixo da banda: queda íngreme (quadrática), ~0 na linha vermelha -18%
--   acima da banda: queda suave, só chegando a um piso baixo perto de +35%
--
-- Grão: (id_loja, dt_pesquisa, categoria_produto) — média simples entre
-- marcas/tamanhos da categoria. categoria_produto vem de dim_produto.
-- JOIN visitas_completas: só entra quem tem os 4 indicadores obrigatórios.
--
-- Confirmado em runtime: MEDIAN() não é suportado como window function no
-- Spark SQL (INVALID_WINDOW_SPEC_FOR_AGGREGATION_FUNC — só aceita ORDER
-- BY/frame em agregações regulares). percentile_approx(x, 0.5) é o
-- equivalente aproximado que o Spark aceita como window function.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_preco (
  CONSTRAINT avg_nota_preco_no_intervalo EXPECT (avg_nota_preco BETWEEN 0 AND 100)
)
COMMENT 'KPI de aderência de preço à mediana móvel de 30 dias por SKU, peso 20% do score.'
AS
WITH preco_base AS (
  SELECT
    p.id_loja,
    p.id_produto,
    dp.categoria_produto,
    p.dt_pesquisa,
    p.preco_observado,
    percentile_approx(p.preco_observado, 0.5) OVER (
      PARTITION BY p.id_produto
      ORDER BY p.dt_pesquisa
      RANGE BETWEEN INTERVAL 30 DAYS PRECEDING AND CURRENT ROW
    ) AS preco_alvo_30d
  FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_preco p
  JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
    ON p.id_loja = vc.id_loja
   AND p.id_produto = vc.id_produto
   AND p.dt_pesquisa = vc.dt_pesquisa
  JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
    ON p.id_produto = dp.id_produto
),
preco_score AS (
  SELECT
    id_loja,
    id_produto,
    categoria_produto,
    dt_pesquisa,
    (preco_observado - preco_alvo_30d) / preco_alvo_30d AS desvio_pct,
    ROUND(
      GREATEST(
        0.01,
        CASE
          WHEN (preco_observado - preco_alvo_30d) / preco_alvo_30d <= -0.18 THEN 0.01
          WHEN (preco_observado - preco_alvo_30d) / preco_alvo_30d < -0.03 THEN
            1 - POWER(
              (ABS((preco_observado - preco_alvo_30d) / preco_alvo_30d) - 0.03) / (0.18 - 0.03),
              2
            )
          WHEN (preco_observado - preco_alvo_30d) / preco_alvo_30d <= 0.05 THEN 1
          ELSE 1 - 10 * POWER(((preco_observado - preco_alvo_30d) / preco_alvo_30d) - 0.05, 2)
        END
      ) * 100,
    2) AS nota_preco
  FROM preco_base
  -- SKU ainda sem 30 dias de histórico não tem alvo — fica de fora até ter
  WHERE preco_alvo_30d IS NOT NULL
)
SELECT
  id_loja,
  dt_pesquisa,
  categoria_produto,
  ROUND(AVG(nota_preco), 2) AS avg_nota_preco
FROM preco_score
GROUP BY
  id_loja,
  dt_pesquisa,
  categoria_produto
