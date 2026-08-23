-- Gold — atendimento_cumprimento_visita
-- Taxa de cumprimento de visita por promotor/loja/dia. Usa source_date
-- (sempre presente) como dimensão de data, em vez de data_checkin (nula
-- quando a visita não é OK). Significado de `atendimento` (dicionário de
-- dados do projeto):
--   OK  = visita realizada com sucesso (check-in/checkout registrados)
--   NP  = "Não Pôde" atender: promotor tentou, mas não conseguiu concluir
--         (loja fechada, responsável ausente, recusa de acesso etc.)
--   X   = visita cancelada/não realizada, nem chegou a tentar (rota
--         reorganizada, loja saiu do roteiro do dia)
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.atendimento_cumprimento_visita (
  -- sem ON VIOLATION DROP ROW: só registra, não esconde o problema.
  CONSTRAINT pct_ok_no_intervalo EXPECT (pct_ok BETWEEN 0 AND 100)
)
COMMENT 'KPI de cumprimento de visita (OK/NP/X), por promotor/loja/dia.'
AS
SELECT
  id_usuario,
  nome,
  id_loja,
  source_date AS dt_visita,
  COUNT(*) AS total_visitas,
  SUM(CASE WHEN atendimento = 'OK' THEN 1 ELSE 0 END) AS qtd_ok,
  SUM(CASE WHEN atendimento = 'NP' THEN 1 ELSE 0 END) AS qtd_np,
  SUM(CASE WHEN atendimento = 'X' THEN 1 ELSE 0 END) AS qtd_x,
  ROUND(100.0 * SUM(CASE WHEN atendimento = 'OK' THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_ok
FROM ${medallion_catalog}.${silver_schema}.atendimentos
GROUP BY id_usuario, nome, id_loja, source_date
