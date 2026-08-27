-- Silver — execucao_pdv_preco_stats
-- Preços estruturalmente válidos (ver execucao_pdv.sql), com mediana, MAD
-- (median absolute deviation) e robust z-score por SKU, e o flag_outlier
-- resultante. Grão de resposta individual, não agregado — existe pra
-- centralizar o cálculo estatístico de preço em um lugar só (evita duplicar
-- mediana/MAD entre execucao_pdv.sql e a gold) e pra auditoria: nenhuma
-- linha é descartada aqui, dá pra inspecionar exatamente quais respostas
-- foram flagadas e por quanto.
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${silver_schema}.execucao_pdv_preco_stats (
  -- sem ON VIOLATION DROP ROW: monitora no painel de qualidade de dados do
  -- Lakeflow. A gold é quem decide excluir outlier do KPI (WHERE
  -- flag_outlier = false); aqui a linha sempre sobrevive, pra auditoria.
  CONSTRAINT preco_nao_outlier EXPECT (NOT flag_outlier)
)
COMMENT 'Preço por resposta com mediana/MAD/robust z-score por SKU e flag_outlier.'
AS
WITH precos AS (
  SELECT id_loja, id_produto, dt_pesquisa, resposta_preco
  FROM ${medallion_catalog}.${silver_schema}.execucao_pdv
  WHERE indicador = 'PRECO' AND resposta_valida
),
-- Mediana e MAD por SKU, só a partir de respostas já estruturalmente
-- válidas (garantido por resposta_valida acima: não nulas, não <= 0).
-- Robust z-score em vez de z-score comum porque mediana/MAD não se deixam
-- puxar pelos próprios outliers que estão sendo caçados (ao contrário de
-- média/desvio-padrão).
preco_stats AS (
  SELECT
    id_produto,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY resposta_preco) AS mediana_preco
  FROM precos
  GROUP BY id_produto
),
preco_mad AS (
  SELECT
    p.id_produto,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ABS(p.resposta_preco - s.mediana_preco)) AS mad_preco
  FROM precos p
  JOIN preco_stats s ON p.id_produto = s.id_produto
  GROUP BY p.id_produto
)
SELECT
  p.id_loja,
  p.id_produto,
  p.dt_pesquisa,
  p.resposta_preco,
  ROUND(s.mediana_preco, 2) AS mediana_preco,
  ROUND(m.mad_preco, 2) AS mad_preco,
  ROUND(
    CASE
      WHEN m.mad_preco > 0
        THEN ABS(0.6745 * (p.resposta_preco - s.mediana_preco) / m.mad_preco)
    END,
    2
  ) AS robust_z_score,
  -- robust z-score > 3.5 (regra padrão Iglewicz & Hoaglin) = outlier estatístico pro SKU.
  -- COALESCE(..., false): sem MAD calculável (produto com histórico
  -- insuficiente), não flaga como outlier — mesma semântica do CASE
  -- original, que só marcava outlier quando a condição batia.
  COALESCE(
    m.mad_preco > 0 AND ABS(0.6745 * (p.resposta_preco - s.mediana_preco) / m.mad_preco) > 3.5,
    false
  ) AS flag_outlier
FROM precos p
LEFT JOIN preco_stats s ON p.id_produto = s.id_produto
LEFT JOIN preco_mad m ON p.id_produto = m.id_produto
