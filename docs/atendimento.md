# Atendimento

## Descrição

Domínio que mede a **atividade de campo dos promotores**: se a visita programada a cada loja
foi de fato cumprida, e quanto tempo o promotor permaneceu na loja.

## Objetivos

- Medir taxa de cumprimento de visita por promotor/loja/dia.
- Medir tempo de permanência em loja (proxy de qualidade da visita).
- Validar geolocalização de check-in/check-out contra o raio esperado do PDV.

## Fluxo de Origem dos Dados

**Extração.** Cada visita chega na bronze (`atendimentos`) com status `atendimento` em três
valores possíveis:

| Status | Significado |
|---|---|
| `OK` | Visita realizada com sucesso (check-in/checkout registrados) |
| `NP` | "Não Pôde" atender — promotor tentou, mas não conseguiu concluir (loja fechada, responsável ausente, recusa de acesso etc.) |
| `X` | Visita cancelada/não realizada — nem chegou a tentar (rota reorganizada, loja saiu do roteiro do dia) |

**Transformação.** A silver
([`atendimentos.sql`](../src/pipelines/trade_analytics/transformations/silver/atendimentos.sql))
tipa data/hora de check-in e check-out, compõe timestamps completos
(`data_hora_checkin`/`data_hora_checkout`), calcula validação geoloc
(`checkin_dentro_raio`/`checkout_dentro_raio`, comparando `distancia_ckin`/`distancia_ckout`
contra `raio_ckin`, só quando `atendimento = 'OK'`), e deduplica defensivamente por
`(id_loja, id_usuario, source_date, data_checkin, hora_checkin)`, mantendo o registro mais
recentemente ingerido (proteção contra reprocessamento do mesmo arquivo dentro da janela de
lookback da bronze). `categoria_loja` também sai aqui, recuperável via `id_loja` +
`gold.dim_loja`.

**Carga.** As duas tabelas gold agregam por `(id_usuario, nome, id_loja, dt_visita)`, onde
`dt_visita` vem de `source_date` (sempre presente, diferente de `data_checkin`, que é nula
quando a visita não é `OK`).

## Especificação Técnica

| Tabela gold | Filtro | Agregação |
|---|---|---|
| `atendimento_cumprimento_visita` | nenhum (todas as visitas) | contagem de `OK`/`NP`/`X` e `% OK` |
| `atendimento_tempo_loja` | `atendimento = 'OK'` e `tempo_loja` não nulo | média/soma de `tempo_loja` |

## Principais Campos

`id_usuario`, `nome` (promotor), `id_loja`, `dt_visita`: grão comum às duas tabelas.
`categoria_loja` fica em `gold.dim_loja` (join por `id_loja`). Detalhamento completo em
[Dicionário de dados](dicionario.md).

## Casos de Uso

- Identificar promotores com taxa de `NP` acima do esperado (possível problema de agenda ou de
  relacionamento com a loja).
- Comparar tempo médio de visita entre categorias de loja.
- Cruzar cumprimento de visita com os KPIs de [execução de PDV](execucao-pdv.md) da mesma
  loja/dia, para avaliar se visitas mais longas correlacionam com melhor execução.
