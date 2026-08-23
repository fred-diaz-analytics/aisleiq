"""
Upload em lote do backfill já gerado localmente (execucao_pdv/, atendimento/)
pro storage S3-compatible. Entrypoint fino — a lógica de upload mora em
lib_geracao.py (enviar_supabase), mesmo padrão de job_diario.py.

Falha isolada por arquivo: um upload com problema não derruba os demais
(mesmo espírito do notebook bronze_ingest.py na pipeline real).

Uso:
  python upload_backfill.py --dominio todos
  python upload_backfill.py --dominio execucao
  python upload_backfill.py --dominio atendimento --out-dir ./data
"""
import argparse
import glob
import os

from dotenv import load_dotenv
from lib_geracao import enviar_supabase


def upload_dominio(out_dir: str, subpasta: str, prefixo_remoto: str) -> tuple[int, int]:
    dias_dir = os.path.join(out_dir, subpasta)
    arquivos = sorted(glob.glob(os.path.join(dias_dir, "*.parquet")))
    print(f"[{subpasta}] {len(arquivos)} arquivos encontrados em {dias_dir}")

    ok, falhou = 0, 0
    for path in arquivos:
        nome = os.path.basename(path)
        remoto = f"{prefixo_remoto}/{nome}"
        try:
            enviar_supabase(path, remoto)
            ok += 1
            print(f"[{subpasta}] OK     {nome}")
        except Exception as e:
            falhou += 1
            print(f"[{subpasta}] FALHOU {nome}: {e}")

    return ok, falhou


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dominio", choices=["execucao", "atendimento", "todos"], default="todos")
    parser.add_argument("--out-dir", default=".", help="pasta com execucao_pdv/ e atendimento/ (default: pasta atual)")
    parser.add_argument("--env-file", default=None, help="caminho do .env com as credenciais do Supabase (default: procura .env na pasta atual)")
    args = parser.parse_args()

    load_dotenv(dotenv_path=args.env_file)

    total_ok, total_falhou = 0, 0
    if args.dominio in ("execucao", "todos"):
        ok, falhou = upload_dominio(args.out_dir, "execucao_pdv", "trade_analytics/execucao_pdv")
        total_ok += ok
        total_falhou += falhou
    if args.dominio in ("atendimento", "todos"):
        ok, falhou = upload_dominio(args.out_dir, "atendimento", "trade_analytics/atendimento")
        total_ok += ok
        total_falhou += falhou

    print(f"\n[resumo] ok={total_ok} | falhou={total_falhou}")
    if total_falhou > 0:
        # falha visível pro shell/CI, mesmo com parte dos arquivos enviada
        raise SystemExit(1)
