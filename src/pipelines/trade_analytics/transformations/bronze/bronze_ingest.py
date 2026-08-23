# Databricks notebook source
# MAGIC %md
# MAGIC # Bronze — Ingestão genérica (Loja Perfeita / trade_analytics)
# MAGIC
# MAGIC Notebook único e parametrizado para os dois domínios da bronze
# MAGIC (`execucao_pdv` e `atendimentos`). O Job orquestrador (`resources/jobs.trade_analytics.yml`)
# MAGIC roda este mesmo notebook duas vezes, mudando só `prefix`/`file_regex`/`table_name`
# MAGIC via `base_parameters`. Evita manter dois arquivos quase idênticos.
# MAGIC
# MAGIC Pipeline de ingestão incremental: baixa arquivos Parquet de um bucket S3-compatible
# MAGIC (Supabase Storage) e grava na camada Bronze como Delta Table, com:
# MAGIC - Watermark por `source_date` (regra de negócio: 1 arquivo = 1 dia, atômico)
# MAGIC - Lookback configurável (reprocessa os últimos N dias por segurança)
# MAGIC - Escrita idempotente via `replaceWhere` (substitui o arquivo sem duplicar,
# MAGIC   em uma única operação atômica, sem janela de risco entre delete e insert)
# MAGIC - Falha isolada por arquivo (um Parquet corrompido não derruba o pipeline inteiro)
# MAGIC - Schema evolution automático via `mergeSchema`
# MAGIC
# MAGIC Roda como Job Task fora do Lakeflow Declarative Pipeline (que cobre só
# MAGIC silver e gold): decisão explícita do projeto, ver README.

# COMMAND ----------

# MAGIC %md
# MAGIC ## Parâmetros do Job
# MAGIC Widgets tornam o notebook reutilizável como Job parametrizado: nada de
# MAGIC constante fixa no código para valores que podem mudar por ambiente/execução
# MAGIC ou por domínio (`prefix`/`file_regex`/`table_name` chegam via `base_parameters`
# MAGIC de cada task no Job). `catalog`/`schema`/`volume_name` chegam resolvidos pelo
# MAGIC bundle a partir de `${var.catalog}` / `${resources.schemas.bronze.name}` /
# MAGIC `${resources.volumes.raw_files.name}`. Nenhum catálogo é hardcoded aqui.

# COMMAND ----------

dbutils.widgets.text("bucket", "datalake", "Bucket S3 (Supabase)")
dbutils.widgets.text("prefix", "trade_analytics/execucao_pdv/", "Prefixo no bucket")
dbutils.widgets.text("file_regex", r"(\d{8}).*execucao_pdv.*\.parquet$", "Regex do nome do arquivo")
dbutils.widgets.text("catalog", "workspace", "Catalog (Unity Catalog)")
dbutils.widgets.text("schema", "bronze", "Schema")
dbutils.widgets.text("table_name", "execucao_pdv", "Nome da tabela Bronze")
dbutils.widgets.text("volume_name", "raw_files", "Volume de staging")
dbutils.widgets.text("lookback_days", "3", "Dias de reprocessamento (watermark)")
dbutils.widgets.text("secret_scope", "supabase", "Secret scope com as credenciais S3")
dbutils.widgets.text("s3_endpoint", "", "Endpoint S3 do Supabase (via base_parameters: ${var.s3_endpoint})")

# COMMAND ----------

import logging
from datetime import UTC, date, datetime, timedelta
from typing import Any, Dict, List, Optional

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

# bronze_lib.py vive na mesma pasta do notebook (Files in Workspace): lógica
# pura (sem dbutils/spark), testada offline em tests/unit/test_bronze_lib.py.
from bronze_lib import match_candidate_files, parse_source_date
from pyspark.sql import DataFrame
from pyspark.sql.functions import current_timestamp, lit

# COMMAND ----------

# MAGIC %md
# MAGIC ## Config
# MAGIC Lida a partir dos widgets: nenhuma credencial ou caminho fica hardcoded aqui.

# COMMAND ----------

BUCKET = dbutils.widgets.get("bucket")
PREFIX = dbutils.widgets.get("prefix")
FILE_REGEX = dbutils.widgets.get("file_regex")

CATALOG = dbutils.widgets.get("catalog")
SCHEMA = dbutils.widgets.get("schema")
TABLE_NAME = dbutils.widgets.get("table_name")
T_BRONZE = f"{CATALOG}.{SCHEMA}.{TABLE_NAME}"
VOLUME_PATH = f"/Volumes/{CATALOG}/{SCHEMA}/{dbutils.widgets.get('volume_name')}"

LOOKBACK_DAYS = int(dbutils.widgets.get("lookback_days"))

SECRET_SCOPE = dbutils.widgets.get("secret_scope")
S3_ENDPOINT = dbutils.widgets.get("s3_endpoint")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
log = logging.getLogger(f"bronze_ingest.{TABLE_NAME}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Setup: schema e volume
# MAGIC Garante que a infraestrutura mínima existe antes de rodar. Idempotente,
# MAGIC seguro rodar em toda execução do Job. Schema e Volume já são criados pelo
# MAGIC bundle como recursos declarativos; isso aqui é só uma segunda garantia.

# COMMAND ----------

def ensure_infra() -> None:
    """Garante schema e volume de staging."""
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {CATALOG}.{SCHEMA}")
    spark.sql(
        f"CREATE VOLUME IF NOT EXISTS {CATALOG}.{SCHEMA}.{dbutils.widgets.get('volume_name')}"
    )
    log.info(f"infra_ok | schema={CATALOG}.{SCHEMA} | volume={VOLUME_PATH}")


# COMMAND ----------

# MAGIC %md
# MAGIC ## Cliente S3 (Supabase Storage)
# MAGIC Credenciais nunca hardcoded, sempre via `dbutils.secrets`. O valor da
# MAGIC secret nunca é logado ou impresso, nem parcialmente.

# COMMAND ----------

def get_s3_client() -> "boto3.client":
    """Cria client boto3 apontando para o endpoint S3-compatible do Supabase.

    Credenciais vêm do secret scope configurado, nunca hardcoded no código.
    """
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
# MAGIC ## Watermark
# MAGIC Última `source_date` já presente na Bronze. Define o corte, junto do
# MAGIC lookback, de quais arquivos precisam ser (re)processados.

# COMMAND ----------

def fetch_max_source_date() -> Optional[date]:
    """Retorna a maior source_date já ingerida, ou None se a tabela não existe.

    Bronze = snapshots raw. O incremental só decide QUAIS arquivos ler;
    a idempotência por arquivo é garantida na escrita (replaceWhere).
    """
    if not spark.catalog.tableExists(T_BRONZE):
        return None
    row = spark.sql(f"SELECT max(source_date) AS d FROM {T_BRONZE}").collect()[0]
    return row["d"]


# COMMAND ----------

# MAGIC %md
# MAGIC ## Listagem de candidatos no S3

# COMMAND ----------

def list_candidate_files(s3, cutoff_yyyymmdd: str) -> List[Dict[str, Any]]:
    """Lista arquivos no bucket cujo nome bate no FILE_REGEX e a data >= cutoff.

    Só paginação/chamada de rede aqui: o matching por regex/cutoff é puro
    e vive em bronze_lib.match_candidate_files (testado offline).
    """
    keys: List[str] = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET, Prefix=PREFIX):
        keys.extend(obj["Key"] for obj in page.get("Contents", []))

    return match_candidate_files(keys, FILE_REGEX, cutoff_yyyymmdd)


# COMMAND ----------

# MAGIC %md
# MAGIC ## Download para o Volume (staging)
# MAGIC O Volume é a "ponte" entre o storage externo e o Spark nativo: permite
# MAGIC `spark.read.parquet` direto, sem passar por pandas no driver.

# COMMAND ----------

def download_to_volume(s3, key: str, name: str) -> str:
    """Baixa um objeto do S3 para o Volume e retorna o caminho local."""
    local_path = f"{VOLUME_PATH}/{name}"
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
        with open(local_path, "wb") as f:
            f.write(obj["Body"].read())
    except ClientError as e:
        raise RuntimeError(f"Falha ao baixar '{key}' do bucket '{BUCKET}'") from e
    return local_path


def cleanup_volume_file(local_path: str) -> None:
    """Remove o arquivo staged do Volume após a carga, para não acumular lixo."""
    try:
        dbutils.fs.rm(local_path.replace("/Volumes", "dbfs:/Volumes"))
    except Exception as e:
        # não é fatal: falha ao limpar staging não deve derrubar o pipeline
        log.warning(f"cleanup_failed | {local_path} | {e}")


# COMMAND ----------

# MAGIC %md
# MAGIC ## Carga na Bronze
# MAGIC Escrita idempotente via `replaceWhere`: substitui atomicamente as linhas
# MAGIC daquele `source_file`, numa única operação, sem a janela de risco de um
# MAGIC `DELETE` seguido de `INSERT` separados.

# COMMAND ----------

def read_source_parquet(local_path: str) -> DataFrame:
    """Lê o Parquet do Volume. Colunas já vêm tipadas e nomeadas pela origem."""
    return spark.read.parquet(local_path)


def load_file_to_bronze(local_path: str, source_file: str, source_date: date) -> int:
    """Grava um arquivo na Bronze de forma idempotente e retorna o row count."""
    sdf = read_source_parquet(local_path)
    sdf = (
        sdf.withColumn("source_file", lit(source_file))
        .withColumn("source_date", lit(source_date.isoformat()).cast("date"))
        .withColumn("ingested_at", current_timestamp())
    )

    row_count = sdf.count()
    table_exists = spark.catalog.tableExists(T_BRONZE)

    writer = (
        sdf.write.format("delta")
        .option("mergeSchema", "true")
    )

    if table_exists:
        # substitui atomicamente só as linhas desse arquivo. Idempotente,
        # sem duplicar em reprocessamentos dentro da janela de lookback
        writer.mode("overwrite").option(
            "replaceWhere", f"source_file = '{source_file}'"
        ).saveAsTable(T_BRONZE)
    else:
        writer.mode("append").saveAsTable(T_BRONZE)

    return row_count


# COMMAND ----------

# MAGIC %md
# MAGIC ## Main
# MAGIC Falha isolada por arquivo: um Parquet com problema é registrado como erro
# MAGIC e o pipeline segue para os demais, em vez de abortar tudo.

# COMMAND ----------

def main() -> None:
    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    log.info(f"START | run_id={run_id} | table={T_BRONZE} | lookback_days={LOOKBACK_DAYS}")

    ensure_infra()
    s3 = get_s3_client()

    max_sd = fetch_max_source_date()
    cutoff_dt = (max_sd - timedelta(days=LOOKBACK_DAYS)) if max_sd else date(1900, 1, 1)
    cutoff_str = cutoff_dt.strftime("%Y%m%d")
    log.info(f"watermark_source_date={max_sd} | cutoff={cutoff_dt} ({cutoff_str})")

    files = list_candidate_files(s3, cutoff_str)
    log.info(f"candidate_files={len(files)}")

    if not files:
        log.info("END | nothing_to_process")
        return

    ok, failed = 0, 0
    for f in files:
        source_date = parse_source_date(f["date_str"])
        log.info(f"FILE_START | {f['name']} | source_date={source_date}")

        local_path = None
        try:
            local_path = download_to_volume(s3, f["key"], f["name"])
            row_count = load_file_to_bronze(local_path, f["name"], source_date)
            log.info(f"FILE_OK | {f['name']} | rows={row_count}")
            ok += 1
        except Exception as e:
            # isola a falha: loga e segue para o próximo arquivo
            log.exception(f"FILE_FAILED | {f['name']} | {e}")
            failed += 1
        finally:
            if local_path:
                cleanup_volume_file(local_path)

    log.info(f"END | run_id={run_id} | ok={ok} | failed={failed} | total={len(files)}")

    if failed > 0:
        # falha visível para o Databricks Job marcar a execução como falha,
        # mesmo que parte dos arquivos tenha sido processada com sucesso
        raise RuntimeError(f"{failed} de {len(files)} arquivos falharam. Ver logs acima.")


# COMMAND ----------

main()
