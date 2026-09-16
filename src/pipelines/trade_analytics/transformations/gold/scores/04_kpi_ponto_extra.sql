-- Score de execução PDV — kpi_ponto_extra
-- KPI 4/5 — Ponto Extra — peso 5%.
-- Linear 0->2 — nota 100 a partir de 2 pontos extras por visita, escala
-- linear abaixo disso.
-- Grão: (id_loja, dt_pesquisa, categoria_produto). categoria_produto vem
-- de dim_produto.
-- JOIN visitas_completas: ponto extra é opcional em si (0 é resposta
-- válida, loja pode legitimamente não ter), não faz parte do gate de
-- completude — mas se a visita é incompleta nos 4 obrigatórios, cai
-- junto: fica fora do score mesmo tendo sido respondido.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_ponto_extra (
  CONSTRAINT avg_nota_ponto_extra_no_intervalo EXPECT (avg_nota_ponto_extra BETWEEN 0 AND 100)
)
COMMENT 'KPI de pontos extras conquistados por visita, peso 5% do score.'
AS
SELECT
  pe.id_loja,
  pe.dt_pesquisa,
  dp.categoria_produto,
  ROUND(AVG(LEAST(100, 100.0 * pe.ponto_extra_medio / 2.0)), 2) AS avg_nota_ponto_extra
FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_ponto_extra pe
JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
  ON pe.id_loja = vc.id_loja
 AND pe.id_produto = vc.id_produto
 AND pe.dt_pesquisa = vc.dt_pesquisa
JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
  ON pe.id_produto = dp.id_produto
GROUP BY
  pe.id_loja,
  pe.dt_pesquisa,
  dp.categoria_produto
