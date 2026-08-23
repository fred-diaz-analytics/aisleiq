"""
Upload dos 5 CSVs do domínio `lojas` (dado mestre, gerados por
export_dim_loja.py) pro storage S3-compatible. Entrypoint fino — a lógica
de upload mora em lib_geracao.py (enviar_supabase), mesmo padrão de
upload_backfill.py.

Diferente de upload_backfill.py: são 5 arquivos fixos (sem data no nome),
recarregados por completo sob demanda — não faz parte do job diário.

Uso:
  python upload_dim_loja.py
  python upload_dim_loja.py --out-dir ./data --env-file ./data/.env
"""
import argparse
import os

from dotenv import load_dotenv
from lib_geracao import enviar_supabase

ARQUIVOS = ["estados.csv", "cidades.csv", "categorias_loja.csv", "redes.csv", "lojas.csv"]
PREFIXO_REMOTO = "trade_analytics/lojas"


def upload_dim_loja(out_dir: str) -> tuple[int, int]:
    ok, falhou = 0, 0
    for nome in ARQUIVOS:
        local = os.path.join(out_dir, nome)
        remoto = f"{PREFIXO_REMOTO}/{nome}"
        try:
            enviar_supabase(local, remoto)
            ok += 1
            print(f"OK     {nome}")
        except Exception as e:
            falhou += 1
            print(f"FALHOU {nome}: {e}")

    return ok, falhou


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=".", help="pasta com os 5 CSVs (default: pasta atual)")
    parser.add_argument("--env-file", default=None, help="caminho do .env com as credenciais do Supabase (default: procura .env na pasta atual)")
    args = parser.parse_args()

    load_dotenv(dotenv_path=args.env_file)

    total_ok, total_falhou = upload_dim_loja(args.out_dir)

    print(f"\n[resumo] ok={total_ok} | falhou={total_falhou}")
    if total_falhou > 0:
        raise SystemExit(1)
