-- Score de execução PDV — qualidade_completude_visita
-- Métrica de monitoramento da regra de completude de visita (00_) — não
-- alimenta o score, é visibilidade: visitas descartadas não desaparecem
-- silenciosamente. Detalha qual dos 4 indicadores obrigatórios faltou
-- mais — diagnóstico operacional (ex.: "está faltando preço
-- sistematicamente" é um problema diferente de "está faltando share").
-- As 4 colunas faltou_* não são mutuamente exclusivas (uma visita pode
-- faltar mais de um indicador) — não somam para visitas_incompletas.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.qualidade_completude_visita (
  CONSTRAINT pct_incompletas_no_intervalo EXPECT (pct_incompletas BETWEEN 0 AND 100)
)
COMMENT 'Monitoramento da regra de completude de visita: % descartado e qual indicador faltou mais.'
AS
WITH universo AS (
  SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca
  UNION SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura
  UNION SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_preco
  UNION SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola
),
flag AS (
  SELECT
    u.id_loja, u.id_produto, u.dt_pesquisa,
    p.id_loja IS NOT NULL AS tem_presenca,
    r.id_loja IS NOT NULL AS tem_ruptura,
    pc.id_loja IS NOT NULL AS tem_preco,
    s.id_loja IS NOT NULL AS tem_share,
    vc.id_loja IS NOT NULL AS completa
  FROM universo u
  LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca p USING (id_loja, id_produto, dt_pesquisa)
  LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura r USING (id_loja, id_produto, dt_pesquisa)
  LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_preco pc USING (id_loja, id_produto, dt_pesquisa)
  LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola s USING (id_loja, id_produto, dt_pesquisa)
  LEFT JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc USING (id_loja, id_produto, dt_pesquisa)
)
SELECT
  COUNT(*) AS total_visitas,
  COUNT(*) FILTER (WHERE completa) AS visitas_completas,
  COUNT(*) FILTER (WHERE NOT completa) AS visitas_incompletas,
  ROUND(100.0 * COUNT(*) FILTER (WHERE NOT completa) / COUNT(*), 2) AS pct_incompletas,
  COUNT(*) FILTER (WHERE NOT completa AND NOT tem_presenca) AS faltou_presenca,
  COUNT(*) FILTER (WHERE NOT completa AND NOT tem_ruptura) AS faltou_ruptura,
  COUNT(*) FILTER (WHERE NOT completa AND NOT tem_preco) AS faltou_preco,
  COUNT(*) FILTER (WHERE NOT completa AND NOT tem_share) AS faltou_share
FROM flag
