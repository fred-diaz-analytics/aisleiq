-- Silver — execucao_pdv
-- Tipa dt_pesquisa/dt_gravacao, limpa `resposta` (texto livre e sujo) para um
-- tipo específico por `indicador`, sinaliza respostas estruturalmente
-- inválidas (sentinelas como -1, percentuais fora de [0,100], preços <= 0).
-- Para PRECO, resposta_valida cobre só a validade estrutural: o outlier
-- estatístico por SKU (robust z-score) vive em execucao_pdv_preco_stats,
-- não aqui — ver comentário da CONSTRAINT resposta_valida_esperada abaixo.
-- remove duplicidade de sync (~3% das respostas são gravadas duas vezes pelo
-- app, mesmo conteúdo, id_pesquisa_resposta novo, dt_gravacao mais tarde;
-- mantém só o primeiro sync) e deduplica por (id_loja, dt_pesquisa): quando
-- mais de um id_usuario registrou pesquisa na mesma loja no mesmo dia,
-- mantém só as respostas do "vencedor" (quem tem mais respostas registradas
-- naquele dia/loja; empate por menor id_usuario). Defensivo, já que hoje
-- id_usuario é fixo por loja.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.execucao_pdv (
  CONSTRAINT id_loja_presente EXPECT (id_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT id_usuario_presente EXPECT (id_usuario IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT dt_pesquisa_presente EXPECT (dt_pesquisa IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT indicador_valido EXPECT (
    indicador IN ('PRESENCA', 'RUPTURA', 'PRECO', 'MPDV', 'PONTO_EXTRA', 'SHARE_GONDOLA')
  ) ON VIOLATION DROP ROW,
  -- sem ON VIOLATION DROP ROW: só monitora no painel de qualidade de dados do
  -- Lakeflow. resposta_valida já cuida de excluir da gold (ver flagged
  -- abaixo). Cobre as regras de negócio estruturais (sentinela -1, faixa
  -- inválida, preço <= 0), uma métrica agregada de "% de respostas válidas"
  -- por run, sem precisar de query customizada. O outlier estatístico de
  -- preço (robust z-score por SKU) não entra aqui — mora em
  -- execucao_pdv_preco_stats.sql, que expõe flag_outlier com seu próprio
  -- EXPECT, pra não duplicar o cálculo de mediana/MAD em dois lugares.
  CONSTRAINT resposta_valida_esperada EXPECT (resposta_valida)
)
COMMENT 'Execução PDV tipada, limpa e deduplicada por (loja, dia).'
AS
WITH typed AS (
  -- produto/marca/categoria_produto saem daqui, recuperáveis via
  -- id_produto + gold.dim_produto (join feito no BI, não em SQL).
  SELECT
    id_pesquisa_resposta,
    id_usuario,
    nome,
    cargo,
    id_loja,
    id_produto,
    indicador,
    grupo_pesquisa,
    desc_pergunta,
    resposta AS resposta_raw,
    checkin_valido,
    COALESCE(
      CASE WHEN dt_pesquisa RLIKE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN to_date(dt_pesquisa, 'yyyy-MM-dd') END,
      CASE WHEN dt_pesquisa RLIKE '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN to_date(dt_pesquisa, 'dd/MM/yyyy') END,
      CASE WHEN dt_pesquisa RLIKE '^[0-9]{8}$' THEN to_date(dt_pesquisa, 'yyyyMMdd') END
    ) AS dt_pesquisa,
    TRY_CAST(to_timestamp(dt_gravacao, 'dd/MM/yyyy HH:mm:ss') AS TIMESTAMP) AS dt_gravacao,
    source_file,
    source_date,
    ingested_at
  FROM ${medallion_catalog}.${bronze_schema}.execucao_pdv
),
clean AS (
  SELECT
    *,
    -- PRESENCA/RUPTURA/MPDV: SIM/NAO -> boolean (tolera variações de encoding em "NÃO")
    CASE
      WHEN indicador IN ('PRESENCA', 'RUPTURA', 'MPDV') THEN
        CASE
          WHEN upper(trim(resposta_raw)) = 'SIM' THEN true
          WHEN upper(trim(resposta_raw)) RLIKE '^N.O$' THEN false
        END
    END AS resposta_bool,
    -- PONTO_EXTRA: contagem inteira (sentinela -1 tratado como resposta inválida abaixo)
    CASE
      WHEN indicador = 'PONTO_EXTRA' AND trim(resposta_raw) RLIKE '^-?[0-9]+$'
        THEN TRY_CAST(trim(resposta_raw) AS INT)
    END AS resposta_numero,
    -- PRECO: remove "R$", troca vírgula por ponto
    CASE
      WHEN indicador = 'PRECO'
        THEN TRY_CAST(replace(replace(trim(resposta_raw), 'R$', ''), ',', '.') AS DECIMAL(10, 2))
    END AS resposta_preco,
    -- SHARE_GONDOLA: remove "%"
    CASE
      WHEN indicador = 'SHARE_GONDOLA'
        THEN TRY_CAST(replace(trim(resposta_raw), '%', '') AS DECIMAL(10, 2))
    END AS resposta_percentual
  FROM typed
),
flagged AS (
  SELECT
    c.*,
    CASE
      WHEN c.indicador = 'PONTO_EXTRA' AND (c.resposta_numero IS NULL OR c.resposta_numero = -1) THEN false
      WHEN c.indicador = 'SHARE_GONDOLA' AND (c.resposta_percentual IS NULL OR c.resposta_percentual < 0 OR c.resposta_percentual > 100) THEN false
      -- validade estrutural só; outlier estatístico (robust z-score por SKU)
      -- é responsabilidade de execucao_pdv_preco_stats.sql, não daqui.
      WHEN c.indicador = 'PRECO' AND (c.resposta_preco IS NULL OR c.resposta_preco <= 0) THEN false
      WHEN c.indicador IN ('PRESENCA', 'RUPTURA', 'MPDV') AND c.resposta_bool IS NULL THEN false
      WHEN c.dt_pesquisa IS NULL THEN false
      ELSE true
    END AS resposta_valida
  FROM clean c
),
dedup_sync AS (
  -- ~3% das respostas são sincronizadas em duplicidade pelo app (mesmo
  -- conteúdo, id_pesquisa_resposta novo, dt_gravacao 30-90min mais tarde).
  -- Mantém só o primeiro sync (menor dt_gravacao) por resposta de negócio.
  SELECT * EXCEPT (rn_sync)
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY id_loja, id_produto, indicador, id_usuario, dt_pesquisa
        ORDER BY dt_gravacao ASC, id_pesquisa_resposta ASC
      ) AS rn_sync
    FROM flagged
  )
  WHERE rn_sync = 1
),
respostas_por_usuario AS (
  SELECT id_loja, dt_pesquisa, id_usuario, COUNT(*) AS total_respostas
  FROM dedup_sync
  WHERE dt_pesquisa IS NOT NULL
  GROUP BY id_loja, dt_pesquisa, id_usuario
),
vencedor AS (
  SELECT id_loja, dt_pesquisa, id_usuario,
    ROW_NUMBER() OVER (
      PARTITION BY id_loja, dt_pesquisa
      ORDER BY total_respostas DESC, id_usuario ASC
    ) AS rn
  FROM respostas_por_usuario
)
SELECT f.*
FROM dedup_sync f
JOIN (SELECT id_loja, dt_pesquisa, id_usuario FROM vencedor WHERE rn = 1) v
  ON f.id_loja = v.id_loja
 AND f.dt_pesquisa = v.dt_pesquisa
 AND f.id_usuario = v.id_usuario
