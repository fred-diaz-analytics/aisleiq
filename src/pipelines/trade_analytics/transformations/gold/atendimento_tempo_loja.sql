-- Gold — atendimento_tempo_loja
-- Tempo de permanência em loja (médio/total) por promotor/loja/dia.
-- Só visitas OK têm tempo_loja preenchido.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.atendimento_tempo_loja (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT tempo_loja_medio_nao_negativo EXPECT (tempo_loja_medio >= 0)
)
COMMENT 'KPI de tempo de permanência em loja, por promotor/loja/dia.'
AS
SELECT
  id_usuario,
  nome,
  id_loja,
  source_date AS dt_visita,
  COUNT(*) AS qtd_visitas_ok,
  ROUND(AVG(tempo_loja), 2) AS tempo_loja_medio,
  ROUND(SUM(tempo_loja), 2) AS tempo_loja_total
FROM ${medallion_catalog}.${silver_schema}.atendimentos
WHERE atendimento = 'OK' AND tempo_loja IS NOT NULL
GROUP BY id_usuario, nome, id_loja, source_date
