-- Score de execução PDV — scores_execucao_pdv
-- Score final — combina os 5 KPIs isolados (01-05) na nota ponderada,
-- por (id_loja, dt_pesquisa, categoria_produto).
-- Pesos: Disponibilidade Efetiva 55% / Preço 20% / Share de Gôndola 15% /
-- Ponto Extra 5% / MPDV 5% (somam 100%).
-- Pilar ausente pro (loja, categoria, dia) — ex. MPDV/ponto extra
-- pulados no app, ou categoria inteira ausente (sem preço/share pra
-- avaliar) — sai do denominador: a nota é re-ponderada só sobre os
-- pilares medidos. "Sem dado" não é "não executou": quem mede a falha de
-- disponibilidade é o pilar de disponibilidade (sempre presente, e já
-- zera o produto ausente). cobertura_pilares_pct expõe quanto do peso
-- total foi de fato medido, pra não comparar nota de 55% de cobertura com
-- nota de 100% sem saber.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.scores_execucao_pdv (
  CONSTRAINT score_execucao_pdv_no_intervalo EXPECT (score_execucao_pdv BETWEEN 0 AND 100),
  CONSTRAINT cobertura_pilares_no_intervalo EXPECT (cobertura_pilares_pct BETWEEN 55 AND 100)
)
COMMENT 'Score ponderado de execução PDV (0-100) por loja/dia/categoria, re-ponderado sobre os pilares medidos.'
AS
WITH pilares AS (
  SELECT
    d.id_loja,
    d.dt_pesquisa,
    d.categoria_produto,
    d.disponibilidade_efetiva,
    d.osa_must_have,
    p.avg_nota_preco,
    s.avg_nota_share,
    pe.avg_nota_ponto_extra,
    m.avg_nota_mpdv,
    0.55
      + CASE WHEN p.avg_nota_preco IS NOT NULL THEN 0.20 ELSE 0 END
      + CASE WHEN s.avg_nota_share IS NOT NULL THEN 0.15 ELSE 0 END
      + CASE WHEN pe.avg_nota_ponto_extra IS NOT NULL THEN 0.05 ELSE 0 END
      + CASE WHEN m.avg_nota_mpdv IS NOT NULL THEN 0.05 ELSE 0 END AS peso_medido
  FROM ${medallion_catalog}.${gold_schema}.kpi_disponibilidade_efetiva d
  LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_preco p
    ON d.id_loja = p.id_loja AND d.dt_pesquisa = p.dt_pesquisa AND d.categoria_produto = p.categoria_produto
  LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_share_gondola s
    ON d.id_loja = s.id_loja AND d.dt_pesquisa = s.dt_pesquisa AND d.categoria_produto = s.categoria_produto
  LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_ponto_extra pe
    ON d.id_loja = pe.id_loja AND d.dt_pesquisa = pe.dt_pesquisa AND d.categoria_produto = pe.categoria_produto
  LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_mpdv m
    ON d.id_loja = m.id_loja AND d.dt_pesquisa = m.dt_pesquisa AND d.categoria_produto = m.categoria_produto
)
SELECT
  id_loja,
  dt_pesquisa,
  categoria_produto,
  disponibilidade_efetiva,
  osa_must_have,
  avg_nota_preco,
  avg_nota_share,
  avg_nota_ponto_extra,
  avg_nota_mpdv,
  ROUND(100 * peso_medido, 2) AS cobertura_pilares_pct,
  ROUND(
    (
      0.55 * disponibilidade_efetiva
      + 0.20 * COALESCE(avg_nota_preco, 0)
      + 0.15 * COALESCE(avg_nota_share, 0)
      + 0.05 * COALESCE(avg_nota_ponto_extra, 0)
      + 0.05 * COALESCE(avg_nota_mpdv, 0)
    ) / peso_medido,
  2) AS score_execucao_pdv
FROM pilares
