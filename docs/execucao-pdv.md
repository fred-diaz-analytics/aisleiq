# Execução de PDV

## Descrição

Domínio que mede a **execução em ponto de venda**: como cada produto está sendo exposto,
precificado e sinalizado na loja, a partir de respostas de pesquisa registradas por promotores
durante a visita. Um único indicador (`indicador`) na tabela silver distingue as seis métricas
abaixo, cada uma virando uma tabela gold própria.

## Objetivos

- Medir presença e ruptura de produto por loja.
- Acompanhar o preço praticado (médio, mínimo, máximo).
- Medir ativação de material de ponto de venda (MPDV) e conquista de ponto extra.
- Medir share de gôndola.
- Servir como base para times de trade marketing avaliarem execução por produto/marca/loja.

## Fluxo de Origem dos Dados

**Extração.** Cada resposta de pesquisa (`id_pesquisa_resposta`) chega na bronze
(`execucao_pdv`) com o `indicador` já definido pelo app de campo (`PRESENCA`, `RUPTURA`,
`PRECO`, `MPDV`, `PONTO_EXTRA` ou `SHARE_GONDOLA`) e a `resposta` como texto livre (ex:
`"SIM"`, `"R$ 12,90"`, `"35%"`, `"-1"`).

**Transformação.** A silver
([`execucao_pdv.sql`](../src/pipelines/trade_analytics/transformations/silver/execucao_pdv.sql))
tipa `resposta` de acordo com o `indicador` (boolean para PRESENCA/RUPTURA/MPDV, inteiro para
PONTO_EXTRA, decimal para PRECO/SHARE_GONDOLA) e sinaliza respostas inválidas
(`resposta_valida`): sentinelas como `-1`, percentuais fora de `[0, 100]`, preços `<= 0`, e
outlier estatístico de preço por SKU (robust z-score sobre mediana/MAD). Também aplica duas
deduplicações: (1) ~3% das respostas são gravadas em duplicidade pelo app, mesmo conteúdo,
`id_pesquisa_resposta` novo, `dt_gravacao` mais tarde; mantém só o primeiro sync. (2) Por
`(id_loja, dt_pesquisa)`, quando mais de um `id_usuario` registrou pesquisa na mesma loja no
mesmo dia, mantém só o "vencedor" (quem tem mais respostas; empate por menor `id_usuario`).
`produto`/`marca`/`categoria_produto` também saem aqui, recuperáveis via `id_produto` +
`gold.dim_produto`.

**Carga.** Cada tabela gold filtra por um `indicador` e agrega por
`(id_loja, id_produto, dt_pesquisa)`, considerando só `resposta_valida = true`.

## Especificação Técnica

| Tabela gold | Filtro (`indicador`) | Agregação |
|---|---|---|
| `execucao_pdv_presenca` | `PRESENCA` | `% resposta_bool = true` |
| `execucao_pdv_ruptura` | `RUPTURA` | `% resposta_bool = true` |
| `execucao_pdv_preco` | `PRECO` | média/mín/máx de `resposta_preco` |
| `execucao_pdv_mpdv` | `MPDV` | `% resposta_bool = true` |
| `execucao_pdv_ponto_extra` | `PONTO_EXTRA` | soma/média de `resposta_numero` |
| `execucao_pdv_share_gondola` | `SHARE_GONDOLA` | média de `resposta_percentual` |

Todas com `CONSTRAINT ... EXPECT` na Lakeflow Declarative Pipeline, sem `ON VIOLATION DROP
ROW`: uma linha de KPI fora do intervalo esperado é registrada, não escondida.

## Score de Execução (Perfect Store)

Pasta `gold/scores/`. Nota 0-100 por `(id_loja, dt_pesquisa, categoria_produto)`:

| Pilar | Peso | Regra | Meta |
|---|---|---|---|
| Disponibilidade efetiva (OSA) | 55% | por SKU: presença × (1 − ruptura); produto ausente = 0; média ponderada pelo valor semanal do SKU | — |
| Preço | 20% | curva assimétrica em torno do preço sugerido (100 dentro da banda, queda íngreme abaixo, suave acima) | `gold.meta_preco` |
| Share de gôndola | 15% | `min(100, share / meta)` | `gold.meta_share` |
| Ponto extra | 5% | linear, 100 a partir de 2 por visita | — |
| MPDV | 5% | % de material ativado | — |

- **Portão de completude** (`visitas_completas`): produto ausente entra só com
  a presença (é a pior falha de disponibilidade e tem que pesar); produto
  presente exige ruptura, preço e share válidos.
- **Pilar sem dado sai do denominador** (re-ponderação): `cobertura_pilares_pct`
  mostra quanto do peso foi medido.
- `osa_must_have`: OSA só dos SKUs must-have, base da flag Perfect Store.
- `kpi_valor_em_risco`: R$/semana do giro esperado dos SKUs indisponíveis
  (ausentes ou em ruptura), pra priorizar por valor e não só por nota.

## Principais Campos

`id_loja`, `id_produto`, `dt_pesquisa`: grão comum às seis tabelas. `produto`/`marca`/
`categoria_produto` ficam em `gold.dim_produto` (join por `id_produto`). Detalhamento completo
em [Dicionário de dados](dicionario.md).

## Casos de Uso

- Ranking de lojas por % de ruptura de uma marca no último mês.
- Acompanhamento de preço médio praticado por categoria de produto.
- Identificar produtos com baixa ativação de material de PDV apesar de alta presença.
