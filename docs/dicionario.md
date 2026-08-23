# Dicionário de Dados

Cobre as tabelas geradas pelo pipeline sintético (`data/lib_geracao.py` +
`data/backfill_2026.py` + `data/job_diario.py`) e como elas se transformam em
cada camada do medalhão (bronze → silver → gold).

> Todos os dados são 100% sintéticos: marcas, produtos, lojas, promotores e
> endereços são fictícios; cidade/UF vêm de geografia pública real
> (`data/cidades_reais.csv`). A geração é determinística (seeds amarradas à
> data + `seed=7` fixo para lojas/promotores), então rodar `backfill_2026.py`
> reproduz exatamente os mesmos arquivos em qualquer máquina.

## 1. `dclientes.csv` — cadastro de lojas (dimensão, gerada uma vez)

Grão: 1 linha por loja. 500 lojas fixas, não recriadas a cada execução.
Estado interno do gerador (gitignored): não vai direto para a bronze;
`id_loja`/`id_usuario`/`categoria_loja` já vêm replicados dentro de
`execucao_pdv`/`atendimento`, e os demais atributos (rede, região, UF,
cidade) são exportados em CSVs próprios que alimentam o domínio `lojas`
(ver seção 2) via `data/export_dim_loja.py`.

| Coluna | Tipo | Descrição |
|---|---|---|
| `id_loja` | int | Identificador único da loja |
| `nome_fantasia` | texto | Nome fictício da loja (Faker) |
| `rede` | texto | Rede/bandeira fictícia — uma das 15 (`REDES` em `lib_geracao.py`) |
| `endereco` | texto | Endereço fictício (rua + número, procedural — não geocodificado, não aponta pra local real) |
| `regiao` | texto | Região do Brasil (Norte/Nordeste/Centro-Oeste/Sudeste/Sul), derivada da UF real |
| `uf` | texto | UF real (extraída de `cidades_reais.csv`) |
| `cidade` | texto | Cidade real correspondente à UF (geografia pública, não identifica o cliente) |
| `categoria_loja` | texto | VAREJO / ATACADO / ATACAREJO — pesos 60/25/15% |
| `periodicidade_visita` | texto | Cadência de visita: SEMANAL (40%) / QUINZENAL (35%) / MENSAL (25%) |
| `dia_semana_visita` | int | Dia da semana fixo da rota dessa loja (0=segunda ... 4=sexta) |
| `semana_par_visita` | bool | Só relevante se `periodicidade_visita = QUINZENAL`: visita em semanas ISO pares ou ímpares |
| `semana_do_mes_visita` | int (1-4) | Só relevante se `periodicidade_visita = MENSAL`: em qual semana do mês a loja é visitada |
| `id_usuario` | int | Promotor fixo responsável por essa loja |
| `nome` | texto | Nome do promotor responsável |
| `cargo` | texto | Sempre `PROMOTOR DE MERCHANDISING` |

## 2. Domínio `lojas` — dado mestre (rede, categoria, cidade, UF, região)

Fonte: 5 CSVs estáticos (`data/estados.csv`, `cidades.csv`,
`categorias_loja.csv`, `redes.csv`, `lojas.csv`, exportados de
`dclientes.csv` via `data/export_dim_loja.py`) → 5 tabelas bronze
(mesmo nome) → 5 tabelas silver (mesmo nome, snowflake) →
**`gold.dim_loja`** (1 tabela, star schema, achatada).

Diferente de `execucao_pdv`/`atendimento`: não é fato diário, não tem
`source_date`/watermark. É dado mestre, recarregado por completo sob
demanda (`bronze_ingest_lojas.py`, job `trade_analytics_lojas`, sem
`schedule`, fora do ciclo automático).

| Tabela (bronze/silver) | Colunas | Chave |
|---|---|---|
| `estados` | `uf`, `nome_estado`, `regiao` | `uf` |
| `cidades` | `id_cidade`, `cidade`, `uf` (FK) | `id_cidade` |
| `categorias_loja` | `id_categoria_loja`, `categoria_loja` | `id_categoria_loja` |
| `redes` | `id_rede`, `nome_rede` | `id_rede` |
| `lojas` | `id_loja`, `nome_fantasia`, `endereco`, `id_cidade` (FK), `id_categoria_loja` (FK), `id_rede` (FK) | `id_loja` |

**`gold.dim_loja`** (star, grão 1 linha por `id_loja`): `id_loja`,
`nome_fantasia`, `endereco`, `rede`, `categoria_loja`, `cidade`, `uf`,
`regiao`, todos já resolvidos via JOIN das 5 tabelas silver, sem FK
para nenhuma outra gold table (join com as gold tables de
`execucao_pdv`/`atendimento` acontece no modelo do Power BI, via
`id_loja`, não em SQL).

## 3. Domínio `produtos` — dado mestre (marca, categoria, tamanho)

Fonte: 2 CSVs estáticos (`data/categorias.csv`, `data/produtos.csv`,
gerados direto do catálogo do gerador via `data/export_dim_produto.py`,
determinístico, sem estado de entrada como `dclientes.csv`) → 2 tabelas
bronze (mesmo nome) → 3 tabelas silver (`categorias`, `marcas`, `produtos`)
→ **`gold.dim_produto`** (1 tabela, star schema, achatada).

Mesmo padrão de `lojas`: dado mestre, recarregado por completo sob demanda
(`bronze_ingest_produtos.py`, job `trade_analytics_produtos`, sem
`schedule`, fora do ciclo automático).

`marca` não tem bronze própria: nunca teve vida própria como cadastro no
catálogo do gerador, só é atributo de produto. Fica embutida em
`bronze.produtos` (`id_marca` + nome juntos); `silver.marcas` é derivada
via `SELECT DISTINCT` de `bronze.produtos`, diferente das demais tabelas
snowflake que vêm de uma bronze própria.

| Tabela | Colunas | Chave | Origem |
|---|---|---|---|
| `categorias` | `id_categoria`, `categoria_produto` | `id_categoria` | bronze própria |
| `marcas` (só silver) | `id_marca`, `marca` | `id_marca` | `SELECT DISTINCT` de `bronze.produtos` |
| `produtos` | `id_produto`, `produto`, `tamanho`, `id_marca` (FK), `id_categoria` (FK) | `id_produto` | bronze própria |

**`gold.dim_produto`** (star, grão 1 linha por `id_produto`): `id_produto`,
`produto`, `tamanho`, `marca`, `categoria_produto`, resolvidos via JOIN
das tabelas silver, sem FK para nenhuma outra gold table (join com as gold
tables de `execucao_pdv` acontece no modelo do Power BI, via `id_produto`,
não em SQL).

## 4. `execucao_pdv` — pesquisa de execução no PDV

Fonte: `execucao_pdv/*.parquet` no storage → **`bronze.execucao_pdv`** →
**`silver.execucao_pdv`** → 6 tabelas gold (uma por indicador).

Grão na origem/bronze: 1 linha por resposta (loja × produto × pergunta ×
visita). Um arquivo por dia, só para lojas visitadas naquele dia (cadência de
`dclientes`).

| Coluna | Tipo | Descrição |
|---|---|---|
| `id_pesquisa_resposta` | int | ID sequencial da resposta, encadeado entre dias (não reinicia) |
| `id_usuario` / `nome` / `cargo` | — | Promotor que respondeu |
| `id_loja` | int | Loja pesquisada |
| `id_produto` | int | Produto avaliado |
| `produto` | texto | Nome do produto (`{marca} {tamanho}`) — só na bronze, ver nota abaixo |
| `marca` | texto | Marca fictícia do produto — só na bronze |
| `categoria_produto` | texto | Uma das 4 categorias FMCG fictícias — só na bronze |
| `indicador` | texto | Grupo macro do indicador (ver catálogo de perguntas, seção 7) |
| `grupo_pesquisa` | texto | Subgrupo da pergunta — hoje sempre igual a `indicador` |
| `desc_pergunta` | texto | Texto da pergunta feita no app |
| `resposta` | texto | Resposta capturada — formato varia por pergunta (ver seção 7); inclui caos proposital de formatação (`4,99` / `R$ 4,99` / `5`) |
| `checkin_valido` | bool | Se o GPS confirmou a presença do promotor na loja no momento da resposta |
| `dt_pesquisa` | texto (`dd/mm/aaaa`) | Data da visita |
| `dt_gravacao` | texto (`dd/mm/aaaa hh:mm:ss`) | Timestamp em que a resposta foi de fato gravada/sincronizada — pode ser minutos depois de `dt_pesquisa`, inclusive gerando duplicidade de sync (~3% das respostas) |

**Colunas adicionadas na bronze** (metadados de ingestão, ver
`src/pipelines/trade_analytics/transformations/bronze/bronze_ingest.py`):
`source_file`, `source_date`, `ingested_at`.

**`produto`/`marca`/`categoria_produto` saem na silver** (normalização, ver
seção 3): a partir daqui só `id_produto`. O texto descritivo é recuperado
via join com `gold.dim_produto` no modelo de BI, não em SQL da pipeline.

**Colunas derivadas na silver** (ver
`src/pipelines/trade_analytics/transformations/silver/execucao_pdv.sql`):
- `dt_pesquisa`/`dt_gravacao` tipadas (`DATE`/`TIMESTAMP`)
- `resposta_bool` — para PRESENCA/RUPTURA/MPDV (`SIM`/`NÃO` → booleano)
- `resposta_numero` — para PONTO_EXTRA (contagem inteira)
- `resposta_preco` — para PRECO (limpa `R$`/vírgula, `DECIMAL`)
- `resposta_percentual` — para SHARE_GONDOLA (remove `%`, `DECIMAL`)
- `resposta_valida` — flag de qualidade: sentinelas (`-1`, percentuais fora de `[0,100]`, preços `<= 0`) e outlier estatístico de preço por SKU (robust z-score sobre mediana/MAD, > 3.5 desvios — pega "dedo gordo" tipo `R$69,00` em vez de `R$6,90`, que passa ileso pelo filtro de sentinela)
- Duplicidade de sync (~3%) removida; dedupe defensivo por loja/dia mantém só o "vencedor" (promotor com mais respostas naquele dia/loja)

## 5. `atendimento` — rotina de visita (check-in/check-out)

Fonte: `atendimento/*.parquet` no storage → **`bronze.atendimentos`** →
**`silver.atendimentos`** → 2 tabelas gold (cumprimento de visita, tempo de
loja).

Grão na origem/bronze: 1 linha por tentativa de visita (não por pergunta). Um
arquivo por dia, mesma cadência de lojas que a execução PDV (é a mesma rota
do promotor).

| Coluna | Tipo | Descrição |
|---|---|---|
| `id_pesquisa_resposta` | int | ID sequencial da visita (sequência própria, separada da execução PDV) |
| `id_usuario` / `nome` / `cargo` | — | Promotor responsável pela visita |
| `id_loja` | int | Loja da visita |
| `categoria_loja` | texto | VAREJO / ATACADO / ATACAREJO — só na bronze, ver nota abaixo |
| `atendimento` | texto | Status da visita — ver seção 6 |
| `data_checkin` / `hora_checkin` | texto | Quando o promotor chegou na loja (nulo se `atendimento != OK`) |
| `data_checkout` / `hora_checkout` | texto | Quando o promotor saiu (nulo se `atendimento != OK`) |
| `raio_ckin` | float | Raio de tolerância do GPS em metros — regra fixa do app (500), não varia por loja |
| `distancia_ckin` | float | Distância real (metros) entre o GPS do promotor e a loja no check-in |
| `distancia_ckout` | float | Idem, no check-out |
| `tempo_loja` | float | Minutos entre check-in e check-out |

**Colunas adicionadas na bronze**: `source_file`, `source_date`, `ingested_at`.

**`categoria_loja` sai na silver** (normalização, ver seção 2): a partir
daqui só `id_loja`, recuperável via join com `gold.dim_loja` no modelo de
BI, não em SQL da pipeline.

**Colunas derivadas na silver** (ver
`src/pipelines/trade_analytics/transformations/silver/atendimentos.sql`):
- `data_checkin`/`data_checkout` tipadas, `data_hora_checkin`/`data_hora_checkout` (`TIMESTAMP`) compostas
- `checkin_dentro_raio` / `checkout_dentro_raio` — validação geoloc (`distancia <= raio_ckin`), a mesma regra dos 500m mencionada no contexto de negócio
- Dedupe defensivo por (loja, usuário, dia de origem, check-in), mantendo o registro mais recentemente ingerido

## 6. Status `atendimento` — o que cada valor significa

| Valor | Significado | % aproximada (calibrado com dado real) |
|---|---|---|
| `OK` | Visita realizada com sucesso — check-in, check-out, tempo e distância preenchidos | 69,1% |
| `NP` | "Não Pôde" atender — promotor tentou, mas não conseguiu completar (loja fechada, responsável ausente, recusa de acesso etc.) | 13,4% |
| `X` | Visita cancelada/não realizada — nem chegou a tentar (rota reorganizada, loja saiu do roteiro do dia) | 17,5% |

## 7. Catálogo de perguntas — execução PDV (referência fixa)

Define o que `indicador` / `grupo_pesquisa` / `desc_pergunta` / formato de
resposta significam. Vive em `PERGUNTAS` no `lib_geracao.py`.

| `indicador` | `desc_pergunta` | Formato de resposta | Opcional? |
|---|---|---|---|
| PRESENCA | PRODUTO PRESENTE ? | SIM / NÃO | Não |
| RUPTURA | PRODUTO ESTA EM RUPTURA ? | SIM / NÃO | Não |
| PRECO | INFORME O PREÇO DO PRODUTO | Valor em R$ (formato inconsistente de propósito: `5,90` / `R$ 5,90` / `6`) | Não |
| MPDV | POSSUI MATERIAL ATIVADO ? | SIM / NÃO | Sim |
| PONTO_EXTRA | INFORME O TOTAL DE PONTO EXTRA | Número inteiro (contagem) | Sim |
| SHARE_GONDOLA | SHARE PROPRIO NA GONDOLA | Percentual (`"34.20 %"`) | Não |

Perguntas opcionais podem ficar ausentes na resposta (puladas no app, mais
provável se `checkin_valido = false`). É por isso que as gold de MPDV e
PONTO_EXTRA têm menos linhas que as demais.

## 8. Catálogo de produtos (referência fixa)

4 categorias fictícias, ~2-3 marcas cada, 3 tamanhos (P/M/G) por marca = 27
produtos. Todas as marcas pertencem ao mesmo grupo (a pesquisa audita o
portfólio completo, não faz benchmark contra concorrência externa). Cada
marca tem sua própria "personalidade" de execução: um desvio determinístico
de até ±15% em torno do baseline de grupo de cada métrica (presença, MPDV,
ruptura, preço, ponto extra, share de gôndola), calculado por
`build_baselines_marca()` em `lib_geracao.py`. Toda marca é pesquisada por
completo em toda visita (sem amostragem parcial). `id_marca`/`id_categoria`
são atribuídos deterministicamente por `build_df_produtos()` (ver seção 3).

| Categoria | Marcas |
|---|---|
| Higiene Pessoal | Suave, PureCare, Bellara |
| Limpeza Doméstica | Brilhare, CleanMax |
| Alimentos | Sabor Caseiro, Grãos & Cia |
| Snacks | CrocanteX, Delicce |

## 9. `estado_execucao.csv` / `estado_atendimento.csv` — estado interno do gerador

Não são dados de negócio: são tabelas de controle do gerador sintético, que
guardam a "memória" usada pra evoluir cada métrica dia a dia (processo tipo
Ornstein-Uhlenbeck) em vez de sortear do zero. Recriadas automaticamente ao
rodar `backfill_2026.py` (não fazem parte do repositório).

- `estado_execucao.csv` (grão loja × produto): `presenca_atual` (bool, estado de listagem persistido), `prob_mpdv`, `taxa_ruptura`, `preco_medio`, `media_ponto_extra`, `media_share_gondola`, `ruptura_ontem` (bool, dá persistência à ruptura), `data_ultima_atualizacao`.
- `estado_atendimento.csv` (grão loja): `tempo_medio`, `distancia_media`, `prob_ok`, `data_ultima_atualizacao`.

## 10. Relacionamentos entre tabelas

```
dclientes (id_loja) ──┬── execucao_pdv (id_loja, id_produto)
                       └── atendimento (id_loja)

dclientes (id_usuario) ── promotor responsável (mesmo em execucao_pdv e atendimento)

execucao_pdv + atendimento compartilham a MESMA cadência de visita
(uma loja aparece nos dois arquivos do mesmo dia, ou em nenhum)

gold.dim_loja (id_loja) ── join 1→N com as gold tables de execucao_pdv/
atendimento via id_loja — feito no modelo do Power BI, não em SQL
(gold.dim_loja não é referenciada por FK em nenhuma outra gold table)

gold.dim_produto (id_produto) ── join 1→N com as 6 gold tables de
execucao_pdv via id_produto — feito no modelo do Power BI, não em SQL
(gold.dim_produto não é referenciada por FK em nenhuma outra gold table)
```
