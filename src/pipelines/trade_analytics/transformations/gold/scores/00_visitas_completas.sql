-- Score de execução PDV — visitas_completas
-- Regra de completude de visita (não pontua sozinha — é o portão de
-- entrada pros outros 5 KPIs desta pasta). Uma visita (id_loja,
-- id_produto, dt_pesquisa) só entra no cálculo do score se tiver as 4
-- respostas obrigatórias válidas (presença, ruptura, preço,
-- share_gôndola) — MPDV/ponto_extra são opcionais e não fazem parte do
-- gate (ponto_extra = 0 é resposta válida, loja pode legitimamente não
-- ter), mas uma visita incompleta nos 4 obrigatórios exclui a visita
-- inteira, inclusive MPDV/ponto_extra que tenham sido respondidos nela.
-- "Válida" já está garantido pela própria construção das 4 gold tables
-- (cada uma filtra resposta_valida na silver) — aqui só checa presença
-- da chave.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.visitas_completas (
  CONSTRAINT chave_presente EXPECT (
    id_loja IS NOT NULL AND id_produto IS NOT NULL AND dt_pesquisa IS NOT NULL
  )
)
COMMENT 'Portão de completude de visita: só (loja, produto, dia) com os 4 indicadores obrigatórios respondidos.'
AS
SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca
INTERSECT
SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura
INTERSECT
SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_preco
INTERSECT
SELECT id_loja, id_produto, dt_pesquisa FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola
