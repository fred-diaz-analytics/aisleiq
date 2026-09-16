-- Score de execução PDV — kpi_disponibilidade_efetiva
-- KPI 1/5 — Disponibilidade Efetiva — peso 55%.
-- presença = SIM E ruptura = NÃO, combinadas num único indicador 0-100
-- como produto de probabilidades (pct_presenca% * pct_disponibilidade%),
-- em vez de AND estritamente binário.
-- Grão: (id_loja, dt_pesquisa, categoria_produto) — média simples entre
-- marcas/tamanhos da categoria. categoria_produto vem de dim_produto: as
-- gold tables de fato (execucao_pdv_*) não carregam atributo de
-- dimensão — join com dim_produto acontece aqui, não embutido na fato.
-- JOIN visitas_completas: regra de completude de visita — só entra quem
-- tem os 4 indicadores obrigatórios respondidos.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.kpi_disponibilidade_efetiva (
  CONSTRAINT disponibilidade_efetiva_no_intervalo EXPECT (disponibilidade_efetiva BETWEEN 0 AND 100)
)
COMMENT 'KPI de disponibilidade efetiva (presença x disponibilidade), peso 55% do score.'
AS
SELECT
  pr.id_loja,
  pr.dt_pesquisa,
  dp.categoria_produto,
  ROUND(AVG(pr.pct_presenca), 2) AS avg_disp,
  ROUND(100 - AVG(rp.pct_ruptura), 2) AS avg_shelf_disp,
  ROUND((AVG(pr.pct_presenca) * (100 - AVG(rp.pct_ruptura))) / POWER(10, 2), 2) AS disponibilidade_efetiva
FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca pr
JOIN ${medallion_catalog}.${gold_schema}.visitas_completas vc
  ON pr.id_loja = vc.id_loja
 AND pr.id_produto = vc.id_produto
 AND pr.dt_pesquisa = vc.dt_pesquisa
JOIN ${medallion_catalog}.${gold_schema}.dim_produto dp
  ON pr.id_produto = dp.id_produto
LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura rp
  ON pr.id_loja = rp.id_loja
 AND pr.id_produto = rp.id_produto
 AND pr.dt_pesquisa = rp.dt_pesquisa
GROUP BY
  pr.id_loja,
  pr.dt_pesquisa,
  dp.categoria_produto
