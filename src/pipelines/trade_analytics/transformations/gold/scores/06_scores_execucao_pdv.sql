-- Score de execução PDV — scores_execucao_pdv
-- Score final — combina os 5 KPIs isolados (01-05) na nota ponderada,
-- por (id_loja, dt_pesquisa, categoria_produto).
-- Pesos: Disponibilidade Efetiva 55% / Preço 20% / Share de Gôndola 15% /
-- Ponto Extra 5% / MPDV 5% (somam 100%).
-- KPI ausente pro (loja, categoria, dia) — ex. preço sem 30 dias de
-- histórico ainda — conta como 0 na nota ponderada (COALESCE), não é
-- excluído do denominador. Trata "sem dado" como "não executou".
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.scores_execucao_pdv (
  CONSTRAINT score_execucao_pdv_no_intervalo EXPECT (score_execucao_pdv BETWEEN 0 AND 100)
)
COMMENT 'Score ponderado de execução PDV (0-100) por loja/dia/categoria.'
AS
SELECT
  d.id_loja,
  d.dt_pesquisa,
  d.categoria_produto,
  d.disponibilidade_efetiva,
  p.avg_nota_preco,
  s.avg_nota_share,
  pe.avg_nota_ponto_extra,
  m.avg_nota_mpdv,
  ROUND(
    0.55 * d.disponibilidade_efetiva
    + 0.20 * COALESCE(p.avg_nota_preco, 0)
    + 0.15 * COALESCE(s.avg_nota_share, 0)
    + 0.05 * COALESCE(pe.avg_nota_ponto_extra, 0)
    + 0.05 * COALESCE(m.avg_nota_mpdv, 0),
  2) AS score_execucao_pdv
FROM ${medallion_catalog}.${gold_schema}.kpi_disponibilidade_efetiva d
LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_preco p
  ON d.id_loja = p.id_loja AND d.dt_pesquisa = p.dt_pesquisa AND d.categoria_produto = p.categoria_produto
LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_share_gondola s
  ON d.id_loja = s.id_loja AND d.dt_pesquisa = s.dt_pesquisa AND d.categoria_produto = s.categoria_produto
LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_ponto_extra pe
  ON d.id_loja = pe.id_loja AND d.dt_pesquisa = pe.dt_pesquisa AND d.categoria_produto = pe.categoria_produto
LEFT JOIN ${medallion_catalog}.${gold_schema}.kpi_mpdv m
  ON d.id_loja = m.id_loja AND d.dt_pesquisa = m.dt_pesquisa AND d.categoria_produto = m.categoria_produto
