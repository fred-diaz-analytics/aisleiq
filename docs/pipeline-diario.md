# Pipeline diário (gerador sintético)

## Descrição

Como não existe um sistema real de PDV/campo por trás deste projeto público, um gerador
sintético determinístico faz esse papel: simula um app de campo publicando arquivos novos todo
dia útil, do mesmo jeito que um sistema real publicaria.

## Objetivos

- Gerar dados sintéticos realistas (sem PII) para as tabelas `execucao_pdv` e `atendimento`.
- Ser 100% reproduzível: mesma seed, mesmo resultado byte-a-byte.
- Simular a evolução contínua de métricas por loja/produto ao longo do tempo (não i.i.d. dia a
  dia).
- Automatizar o catch-up: um único run recupera qualquer quantidade de dias perdidos.

## Fluxo de Origem dos Dados

**Geração** ([`data/lib_geracao.py`](../data/lib_geracao.py)):
- Dimensão de lojas (`dclientes.csv`) e produtos/marcas gerados uma vez, com seed fixa (`7`).
- Cada dia (`data_ref`) usa uma seed derivada da própria data
  (`seed_dia = int(data_ref.strftime("%Y%m%d"))`, com offset `+1` para o domínio atendimento,
  garantindo que os dois domínios não compartilhem o mesmo stream aleatório).
- Métricas por loja/produto evoluem dia a dia por um processo Ornstein-Uhlenbeck simplificado
  (`novo = valor + theta*(baseline - valor) + ruído`, com bounds). Não são sorteadas do zero a
  cada dia, o que produz séries temporais realistas (tendências, não ruído puro).
- Cadência de visita por loja (`NUCLEO`/`SEMANAL`/`QUINZENAL`/`MENSAL`/`ESPORADICA`) definida na
  dimensão de lojas.

**Seed histórico** ([`data/backfill_2026.py`](../data/backfill_2026.py)): gera o histórico de
2026-01-01 até 2026-08-10 de uma vez, persistindo o estado final em `estado_execucao.csv` /
`estado_atendimento.csv`, o ponto de partida pro catch-up diário continuar de onde parou.
[`upload_backfill.py`](../data/upload_backfill.py) sobe esse backfill para o Supabase Storage.

**Catch-up diário** ([`data/job_diario.py`](../data/job_diario.py)): entrypoint local (não roda
no Databricks, é o "sistema de origem" simulado). Sem `--data`, detecta sozinho o último dia
já gerado (maior data entre os arquivos parquet existentes) e gera todo dia útil faltante até
hoje, pulando fins de semana:

```
dias_uteis_faltantes(ultima_data_gerada(dias_dir), hoje)
```

Se ficar dias sem rodar, um único run cobre o buraco inteiro. Com `--upload-supabase`, cada dia
gerado é imediatamente enviado ao bucket S3-compatible, no mesmo formato de nome que o `Job`
Databricks espera (`(\d{8}).*execucao_pdv.*\.parquet$` / `(\d{8}).*atendimento.*\.parquet$`).

## Especificação Técnica

| Script | Papel | Estado que consome/produz |
|---|---|---|
| `lib_geracao.py` | Lógica pura de geração (sem I/O de rede) | lê/escreve `estado_execucao.csv`, `estado_atendimento.csv` |
| `backfill_2026.py` | Seed histórico, roda uma vez | cria `dclientes.csv` + estado inicial |
| `job_diario.py` | Catch-up diário, entrypoint local | lê estado, gera parquet, opcionalmente sobe pro Supabase |
| `upload_backfill.py` | Sobe o backfill histórico | lê parquet local, escreve no bucket |

```bash
python job_diario.py --dominio todos --out-dir . --env-file .env --upload-supabase
```

O `job_diario.py` **não roda no Databricks**: é um script local que simula a origem dos
dados. A ponte entre ele e o pipeline real é só o bucket S3-compatible: o que ele sobe, o Job
`bronze_ingest.py` (rodando no Databricks) lista e ingere.

**Freeze do repositório**: os arquivos parquet commitados em `data/execucao_pdv/` e
`data/atendimento/` são um snapshot fixo até **2026-08-21**, mantido pra o repositório ficar
imediatamente executável sem precisar gerar nada antes. O catch-up diário continua rodando
localmente e subindo pro Supabase normalmente, só que arquivos gerados depois dessa data não
entram em novos commits (`.gitignore` bloqueia só as datas futuras/ainda não rastreadas; o que
já está commitado não é afetado, então isso não exige manutenção). Quem quiser dado sintético
mais recente localmente roda `backfill_2026.py`/`job_diario.py` por conta própria.

Colunas de `execucao_pdv`/`atendimentos` em [Dicionário de dados](dicionario.md).

## Casos de Uso

- Popular um ambiente de dev/teste do zero sem depender de um sistema de origem real.
- Demonstrar um pipeline de dados completo (geração → storage → ingestão → transformação →
  KPI) de ponta a ponta, de forma reproduzível.
- Simular gaps de operação (rodar o catch-up depois de vários dias parado) sem perder histórico.
