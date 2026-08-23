-- Gold — dim_produto
-- Star schema: achata as tabelas snowflake da silver (`produtos`, `marcas`,
-- `categorias`) numa única dimensão, grão 1 linha por id_produto, sem FK pra
-- nenhuma outra gold table (join com marca/categoria acontece no modelo do
-- Power BI).
CREATE OR REFRESH MATERIALIZED VIEW ${medallion_catalog}.${gold_schema}.dim_produto (
  CONSTRAINT id_produto_presente EXPECT (id_produto IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Dimensão de produto (marca, categoria, tamanho) — star schema.'
AS
SELECT
  p.id_produto,
  p.produto,
  p.tamanho,
  m.marca,
  c.categoria_produto
FROM ${medallion_catalog}.${silver_schema}.produtos p
LEFT JOIN ${medallion_catalog}.${silver_schema}.marcas m ON p.id_marca = m.id_marca
LEFT JOIN ${medallion_catalog}.${silver_schema}.categorias c ON p.id_categoria = c.id_categoria
