-- Score de execução PDV — visitas_completas
-- Regra de completude de visita (não pontua sozinha — é o portão de
-- entrada pros outros KPIs desta pasta). Presença é o portão: o app só
-- pergunta ruptura/preço/share/MPDV/ponto extra de produto presente (ver
-- gerar_bronze_dia_stateful em data/lib_geracao.py). Então uma visita
-- (id_loja, id_produto, dt_pesquisa) é completa quando:
--   - presença = NÃO (produto ausente/deslistado): completa só com a
--     presença — é justamente a pior falha de execução e TEM que entrar no
--     score (antes caía fora, porque exigia os 4 obrigatórios, e a loja
--     com produto deslistado pontuava igual a loja com mix completo);
--   - presença = SIM: exige também ruptura, preço e share_gôndola válidos.
-- MPDV/ponto_extra são opcionais e não fazem parte do gate (ponto_extra = 0
-- é resposta válida), mas caem junto se a visita for incompleta.
-- "Válida" já está garantido pela construção das gold tables (cada uma
-- filtra resposta_valida na silver) — aqui só checa presença da chave.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.visitas_completas (
  CONSTRAINT chave_presente EXPECT (
    id_loja IS NOT NULL AND id_produto IS NOT NULL AND dt_pesquisa IS NOT NULL
  )
)
COMMENT 'Portão de completude de visita: produto ausente entra só com presença; presente exige ruptura, preço e share.'
AS
SELECT
  pr.id_loja,
  pr.id_produto,
  pr.dt_pesquisa,
  pr.total_presente > 0 AS presente
FROM ${medallion_catalog}.${gold_schema}.execucao_pdv_presenca pr
LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_ruptura rp
  USING (id_loja, id_produto, dt_pesquisa)
LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_preco pc
  USING (id_loja, id_produto, dt_pesquisa)
LEFT JOIN ${medallion_catalog}.${gold_schema}.execucao_pdv_share_gondola sg
  USING (id_loja, id_produto, dt_pesquisa)
WHERE pr.total_presente = 0
   OR (rp.id_loja IS NOT NULL AND pc.id_loja IS NOT NULL AND sg.id_loja IS NOT NULL)
