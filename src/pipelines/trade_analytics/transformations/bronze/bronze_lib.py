"""Lógica pura da ingestão bronze, sem dependência de dbutils/spark.

Extraída de `bronze_ingest.py` pra ser testável offline (pytest, sem
credencial nem cluster, ver `tests/unit/test_bronze_lib.py`). O notebook
importa estas funções e cuida só da parte que exige o runtime Databricks
(widgets, Volumes, Delta, secrets, download via boto3).
"""
import re
from datetime import date, datetime
from typing import Any, Dict, List


def parse_source_date(date_str: str) -> date:
    """Converte 'YYYYMMDD' (extraído do nome do arquivo) em date."""
    return datetime.strptime(date_str, "%Y%m%d").date()


def match_candidate_files(keys: List[str], file_regex: str, cutoff_yyyymmdd: str) -> List[Dict[str, Any]]:
    """Filtra e ordena chaves de objeto S3 pelo regex do nome do arquivo e
    por um corte de data (watermark).

    Não faz nenhuma chamada de rede: recebe a lista de chaves já listada
    pelo caller (`list_candidate_files`, que pagina o S3 de verdade).
    """
    pat = re.compile(file_regex)
    out: List[Dict[str, Any]] = []

    for key in keys:
        name = key.split("/")[-1]
        m = pat.search(name)
        if not m:
            continue
        date_str = m.group(1)
        if date_str >= cutoff_yyyymmdd:
            out.append({"key": key, "date_str": date_str, "name": name})

    out.sort(key=lambda x: x["date_str"])
    return out
