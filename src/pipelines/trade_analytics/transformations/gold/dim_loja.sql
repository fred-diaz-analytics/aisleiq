-- Gold — dim_loja
-- Star schema: achata as 5 tabelas snowflake da silver (`lojas`) numa
-- única dimensão, grão 1 linha por id_loja, sem FK pra nenhuma outra
-- gold table (join com rede/categoria/região acontece no modelo do
-- Power BI).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.dim_loja (
  CONSTRAINT id_loja_presente EXPECT (id_loja IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Dimensão de loja (rede, categoria, cidade, UF, região) — star schema.'
AS
SELECT
  l.id_loja,
  l.nome_fantasia,
  l.endereco,
  r.nome_rede AS rede,
  cl.categoria_loja,
  c.cidade,
  e.uf,
  e.regiao
FROM ${medallion_catalog}.${silver_schema}.lojas l
LEFT JOIN ${medallion_catalog}.${silver_schema}.redes r ON l.id_rede = r.id_rede
LEFT JOIN ${medallion_catalog}.${silver_schema}.categorias_loja cl ON l.id_categoria_loja = cl.id_categoria_loja
LEFT JOIN ${medallion_catalog}.${silver_schema}.cidades c ON l.id_cidade = c.id_cidade
LEFT JOIN ${medallion_catalog}.${silver_schema}.estados e ON c.uf = e.uf
