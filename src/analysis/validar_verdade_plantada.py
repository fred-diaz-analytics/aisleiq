# Databricks notebook source
# MAGIC %md
# MAGIC # Validação — o score reencontra os efeitos plantados?
# MAGIC
# MAGIC O gerador sintético planta efeitos conhecidos (rede com reposição ruim,
# MAGIC rede em guerra de preço, rede de excelência, 35 lojas críticas,
# MAGIC decaimento por cadência de visita — ver `efeitos_loja()` em
# MAGIC `data/lib_geracao.py`). Este notebook cruza o gabarito
# MAGIC (`verdade_plantada.csv`, gerado por `data/export_verdade_plantada.py`)
# MAGIC com a gold e checa se o score de execução enxerga o que foi plantado.
# MAGIC
# MAGIC Fora da pipeline de propósito: o gabarito nunca vira tabela do
# MAGIC lakehouse. Subir o CSV manualmente pro volume antes de rodar:
# MAGIC `databricks fs cp data/verdade_plantada.csv`
# MAGIC `dbfs:/Volumes/<catalog>/bronze/raw_files/validacao/verdade_plantada.csv`

# COMMAND ----------

dbutils.widgets.text("catalog", "aisleiq_dev", "Catalog (Unity Catalog)")
dbutils.widgets.text("gold_schema", "gold", "Schema gold")
GABARITO_PADRAO = "/Volumes/aisleiq_dev/bronze/raw_files/validacao/verdade_plantada.csv"
dbutils.widgets.text("gabarito_path", GABARITO_PADRAO, "CSV do gabarito")
dbutils.widgets.text("janela_semanas", "12", "Janela do score por loja (semanas)")
dbutils.widgets.text("min_visitas", "4", "Mínimo de visitas na janela pra entrar no ranking")

# COMMAND ----------

import numpy as np

CATALOG = dbutils.widgets.get("catalog")
GOLD = f"{CATALOG}.{dbutils.widgets.get('gold_schema')}"
JANELA_DIAS = int(dbutils.widgets.get("janela_semanas")) * 7
MIN_VISITAS = int(dbutils.widgets.get("min_visitas"))

EFEITOS_LOJA = ["critica", "rede_ruptura", "rede_guerra_preco", "rede_excelencia"]
gabarito = spark.read.csv(dbutils.widgets.get("gabarito_path"), header=True, inferSchema=True).toPandas()
for col in EFEITOS_LOJA:
    gabarito[col] = gabarito[col].astype(str).str.lower() == "true"

resultados = []


def checar(nome: str, ok: bool, detalhe: str) -> None:
    resultados.append({"criterio": nome, "ok": bool(ok), "detalhe": detalhe})
    print(f"[{'OK ' if ok else 'FALHOU'}] {nome}: {detalhe}")


# COMMAND ----------

# MAGIC %md
# MAGIC ## Score por loja na janela
# MAGIC Média do score diário (média das categorias) nas últimas N semanas, só
# MAGIC lojas com visitas suficientes — loja ESPORADICA com 1 visita é ruído.

# COMMAND ----------

# CAST AS DOUBLE: as colunas da gold são DECIMAL, que o toPandas() traz como
# objeto Decimal (dtype object) e quebra .round()/.corr() do pandas.
score_loja = spark.sql(f"""
  WITH corte AS (SELECT MAX(dt_pesquisa) - INTERVAL {JANELA_DIAS} DAYS AS dt_min FROM {GOLD}.scores_execucao_pdv),
  dia AS (
    SELECT s.id_loja, s.dt_pesquisa,
           AVG(CAST(s.score_execucao_pdv AS DOUBLE)) AS score,
           AVG(CAST(s.avg_nota_preco AS DOUBLE)) AS nota_preco,
           AVG(CAST(s.disponibilidade_efetiva AS DOUBLE)) AS disponibilidade
    FROM {GOLD}.scores_execucao_pdv s, corte
    WHERE s.dt_pesquisa > corte.dt_min
    GROUP BY s.id_loja, s.dt_pesquisa
  )
  SELECT id_loja, COUNT(*) AS visitas, AVG(score) AS score, AVG(nota_preco) AS nota_preco,
         AVG(disponibilidade) AS disponibilidade
  FROM dia GROUP BY id_loja
""").toPandas()

base = score_loja.merge(gabarito, on="id_loja", how="inner")
ranking = base[base["visitas"] >= MIN_VISITAS].copy()
print(f"lojas com score: {len(base)} | no ranking (>= {MIN_VISITAS} visitas): {len(ranking)}")

# COMMAND ----------

# 1. Score ordena as lojas como a severidade plantada (quanto mais severo, menor o score)
# spearman = pearson sobre os ranks (sem depender de scipy)
rho = ranking["score"].rank().corr((-ranking["severidade_esperada"]).rank())
checar("spearman(score, -severidade) >= 0.6", rho >= 0.6, f"rho = {rho:.3f}")

# 2. Lojas críticas no quintil inferior
corte_q1 = ranking["score"].quantile(0.2)
criticas = ranking[ranking["critica"]]
pct_q1 = (criticas["score"] <= corte_q1).mean() if len(criticas) else float("nan")
checar("críticas no quintil inferior >= 70%", pct_q1 >= 0.7, f"{pct_q1:.0%} de {len(criticas)} críticas no ranking")

# 3. Guerra de preço aparece na nota de preço
guerra = base.loc[base["rede_guerra_preco"], "nota_preco"].mean()
demais = base.loc[~base["rede_guerra_preco"], "nota_preco"].mean()
checar("nota de preço: guerra >= 30 pts abaixo", demais - guerra >= 30, f"guerra={guerra:.1f} | demais={demais:.1f}")

# COMMAND ----------

# 4. Decaimento por cadência: ruptura observada cresce com o intervalo entre visitas
ruptura_cadencia = spark.sql(f"""
  SELECT id_loja, AVG(CAST(pct_ruptura AS DOUBLE)) AS pct_ruptura
  FROM {GOLD}.execucao_pdv_ruptura GROUP BY id_loja
""").toPandas().merge(gabarito, on="id_loja")
sem_efeito_loja = ruptura_cadencia[~ruptura_cadencia[EFEITOS_LOJA].any(axis=1)]
por_cadencia = sem_efeito_loja.groupby("periodicidade_visita")["pct_ruptura"].mean()
print(por_cadencia.sort_values())
ok_cadencia = (
    por_cadencia.get("MENSAL", np.nan) > por_cadencia.get("SEMANAL", np.nan) > por_cadencia.get("NUCLEO", np.nan)
)
checar("ruptura: MENSAL > SEMANAL > NUCLEO", ok_cadencia, por_cadencia.round(2).to_dict().__repr__())

# COMMAND ----------

# 5. Produto ausente agora pesa no score (antes sumia no portão de completude)
ausentes = spark.sql(f"SELECT skus_ausentes FROM {GOLD}.qualidade_completude_visita").first()["skus_ausentes"]
checar("SKUs ausentes entram no score", ausentes > 0, f"{ausentes} SKU-visitas ausentes")

# COMMAND ----------

# 6. Controle negativo: promotor não tem efeito plantado. Teste de permutação
#    sobre as lojas sem nenhum efeito de loja/rede — a variância entre
#    promotores não deve ser maior do que o acaso produz.
neutras = ranking[~ranking[EFEITOS_LOJA].any(axis=1)]
# remove a parte explicada pela cadência (efeito plantado) antes de comparar promotores
residuo = neutras["score"] - neutras.groupby("periodicidade_visita")["score"].transform("mean")


def var_entre(valores, grupos) -> float:
    return valores.groupby(grupos).mean().var()


observado = var_entre(residuo, neutras["id_usuario"])
rng = np.random.default_rng(7)
permutado = [var_entre(residuo, rng.permutation(neutras["id_usuario"].values)) for _ in range(1000)]
p_valor = float(np.mean([p >= observado for p in permutado]))
checar("promotor sem efeito (p >= 0.05)", p_valor >= 0.05, f"p = {p_valor:.3f}")

# COMMAND ----------

display(spark.createDataFrame(resultados))
falhas = [r["criterio"] for r in resultados if not r["ok"]]
if falhas:
    print(f"{len(falhas)} critério(s) falharam: {falhas}")
