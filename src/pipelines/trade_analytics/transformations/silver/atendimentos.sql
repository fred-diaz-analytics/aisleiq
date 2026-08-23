-- Silver — atendimentos
-- Tipa datas/horas de check-in/check-out, compõe timestamps completos, calcula
-- a validação geoloc (check-in/check-out dentro do raio de 500m do PDV) e
-- deduplica defensivamente por (loja, usuário, dia de origem, check-in),
-- mantendo o registro mais recentemente ingerido, como proteção contra
-- reprocessamento do mesmo arquivo dentro da janela de lookback da bronze.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.atendimentos (
  CONSTRAINT id_loja_presente EXPECT (id_loja IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT id_usuario_presente EXPECT (id_usuario IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT atendimento_valido EXPECT (atendimento IN ('OK', 'NP', 'X')) ON VIOLATION DROP ROW,
  CONSTRAINT tempo_loja_nao_negativo EXPECT (tempo_loja IS NULL OR tempo_loja >= 0) ON VIOLATION DROP ROW
)
COMMENT 'Atendimentos (visitas) tipados, com validação geoloc e dedupe defensivo.'
AS
WITH typed AS (
  -- categoria_loja sai daqui -- recuperável via id_loja + gold.dim_loja
  -- (join feito no BI, não em SQL).
  SELECT
    id_pesquisa_resposta,
    id_usuario,
    nome,
    cargo,
    id_loja,
    atendimento,
    CASE WHEN data_checkin RLIKE '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN to_date(data_checkin, 'dd/MM/yyyy') END AS data_checkin,
    hora_checkin,
    CASE WHEN data_checkout RLIKE '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN to_date(data_checkout, 'dd/MM/yyyy') END AS data_checkout,
    hora_checkout,
    raio_ckin,
    distancia_ckin,
    distancia_ckout,
    tempo_loja,
    source_file,
    source_date,
    ingested_at
  FROM ${medallion_catalog}.${bronze_schema}.atendimentos
),
composed AS (
  SELECT
    *,
    CASE WHEN data_checkin IS NOT NULL AND hora_checkin IS NOT NULL
      THEN to_timestamp(concat(date_format(data_checkin, 'yyyy-MM-dd'), ' ', hora_checkin))
    END AS data_hora_checkin,
    CASE WHEN data_checkout IS NOT NULL AND hora_checkout IS NOT NULL
      THEN to_timestamp(concat(date_format(data_checkout, 'yyyy-MM-dd'), ' ', hora_checkout))
    END AS data_hora_checkout
  FROM typed
),
flagged AS (
  SELECT
    *,
    -- validação geoloc: só faz sentido quando a visita foi OK (com check-in real)
    CASE WHEN atendimento = 'OK' THEN distancia_ckin <= raio_ckin END AS checkin_dentro_raio,
    CASE WHEN atendimento = 'OK' THEN distancia_ckout <= raio_ckin END AS checkout_dentro_raio
  FROM composed
),
ranked AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY id_loja, id_usuario, source_date, data_checkin, hora_checkin
      ORDER BY ingested_at DESC
    ) AS rn
  FROM flagged
)
SELECT * EXCEPT (rn)
FROM ranked
WHERE rn = 1
