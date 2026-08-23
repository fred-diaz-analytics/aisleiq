# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze — Ingestão do domínio `produtos` (dado mestre)
# MAGIC
# MAGIC Mesmo padrão de `bronze_ingest_lojas.py`: dado mestre estático, 2 CSVs
# MAGIC fixos (`categorias`, `produtos`), sem partição por data, recarregados por
# MAGIC completo a cada execução (`CREATE OR REPLACE TABLE`, sem watermark/
# MAGIC lookback/`replaceWhere`). Roda sob demanda, via Job próprio
# MAGIC (`trade_analytics_produtos`), não entra no job diário agendado.

# COMMAND ----------

dbutils.widgets.text("bucket", "datalake", "Bucket S3 (Supabase)")
dbutils.widgets.text("prefix", "trade_analytics/produtos/", "Prefixo no bucket")
dbutils.widgets.text("catalog", "workspace", "Catalog (Unity Catalog)")
dbutils.widgets.text("schema", "bronze", "Schema")
dbutils.widgets.text("volume_name", "raw_files", "Volume de staging")
dbutils.widgets.text("secret_scope", "supabase", "Secret scope com as credenciais S3")
dbutils.widgets.text("s3_endpoint", "", "Endpoint S3 do Supabase (via base_parameters: ${var.s3_endpoint})")

# COMMAND ----------

import logging

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError
from pyspark.sql.functions import current_timestamp

# COMMAND ----------

BUCKET = dbutils.widgets.get("bucket")
PREFIX = dbutils.widgets.get("prefix")

CATALOG = dbutils.widgets.get("catalog")
SCHEMA = dbutils.widgets.get("schema")
VOLUME_PATH = f"/Volumes/{CATALOG}/{SCHEMA}/{dbutils.widgets.get('volume_name')}"

SECRET_SCOPE = dbutils.widgets.get("secret_scope")
S3_ENDPOINT = dbutils.widgets.get("s3_endpoint")

TABELAS = ["categorias", "produtos"]

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("bronze_ingest_produtos")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Setup: schema e volume
# MAGIC Reaproveita os mesmos recursos (`bronze`/`raw_files`) já usados pelos
# MAGIC outros domínios: não precisa de schema/volume próprio.

# COMMAND ----------

def ensure_infra() -> None:
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.{SCHEMA}")
    spark.sql(f"CREATE VOLUME IF NOT EXISTS {CATALOG}.{SCHEMA}.{dbutils.widgets.get('volume_name')}")
    log.info(f"infra_ok | schema={CATALOG}.{SCHEMA} | volume={VOLUME_PATH}")


# COMMAND ----------

def get_s3_client() -> "boto3.client":
    """Credenciais vêm do secret scope configurado, nunca hardcoded no código."""
    try:
        access_key = dbutils.secrets.get(SECRET_SCOPE, "access_key_id")
        secret_key = dbutils.secrets.get(SECRET_SCOPE, "secret_access_key")
    except Exception as e:
        raise RuntimeError(
            f"Falha ao carregar credenciais do secret scope '{SECRET_SCOPE}'. "
            f"Verifique se o scope e as keys 'access_key_id'/'secret_access_key' existem."
        ) from e

    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="us-east-1",
        config=Config(
            s3={"addressing_style": "path"},
            retries={"max_attempts": 5, "mode": "standard"},
            connect_timeout=15,
            read_timeout=120,
        ),
    )


# COMMAND ----------

# MAGIC %md
# MAGIC ## Carga full-reload
# MAGIC Sem watermark, sem `replaceWhere`: cada tabela é substituída por
# MAGIC inteiro a cada execução (dado mestre, não fato particionado por dia).

# COMMAND ----------

def download_to_volume(s3, key: str, nome: str) -> str:
    local_path = f"{VOLUME_PATH}/{nome}.csv"
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
        with open(local_path, "wb") as f:
            f.write(obj["Body"].read())
    except ClientError as e:
        raise RuntimeError(f"Falha ao baixar '{key}' do bucket '{BUCKET}'") from e
    return local_path


def cleanup_volume_file(local_path: str) -> None:
    try:
        dbutils.fs.rm(local_path.replace("/Volumes", "dbfs:/Volumes"))
    except Exception as e:
        log.warning(f"cleanup_failed | {local_path} | {e}")


def load_table_full_reload(s3, nome: str) -> int:
    key = f"{PREFIX}{nome}.csv"
    local_path = download_to_volume(s3, key, nome)
    try:
        sdf = spark.read.csv(local_path, header=True, inferSchema=True)
        sdf = sdf.withColumn("ingested_at", current_timestamp())
        row_count = sdf.count()
        sdf.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable(
            f"{CATALOG}.{SCHEMA}.{nome}"
        )
        return row_count
    finally:
        cleanup_volume_file(local_path)


# COMMAND ----------

# MAGIC %md
# MAGIC ## Main
# MAGIC Falha isolada por tabela: um CSV com problema é registrado como erro e
# MAGIC o run segue para as demais, em vez de abortar tudo.

# COMMAND ----------

def main() -> None:
    log.info(f"START | catalog={CATALOG} | schema={SCHEMA} | tabelas={TABELAS}")

    ensure_infra()
    s3 = get_s3_client()

    ok, failed = 0, 0
    for nome in TABELAS:
        try:
            row_count = load_table_full_reload(s3, nome)
            log.info(f"TABLE_OK | {nome} | rows={row_count}")
            ok += 1
        except Exception as e:
            log.exception(f"TABLE_FAILED | {nome} | {e}")
            failed += 1

    log.info(f"END | ok={ok} | failed={failed} | total={len(TABELAS)}")

    if failed > 0:
        raise RuntimeError(f"{failed} de {len(TABELAS)} tabelas falharam. Ver logs acima.")


# COMMAND ----------

main()
