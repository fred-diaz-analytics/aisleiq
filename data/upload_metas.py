"""
Upload dos CSVs do domínio `metas` (metas comerciais, gerados por
export_metas.py) pro storage S3-compatible. Entrypoint fino — a lógica
de upload mora em lib_geracao.py (enviar_supabase), mesmo padrão de
upload_dim_produto.py.

São arquivos fixos (sem data no nome), recarregados por completo sob
demanda — não faz parte do job diário.

Uso:
  python upload_metas.py
  python upload_metas.py --out-dir ./data --env-file ./data/.env
"""
import argparse
import os

from dotenv import load_dotenv
from lib_geracao import enviar_supabase

ARQUIVOS = ["preco_sugerido.csv", "sku_prioridade.csv", "meta_share.csv"]
PREFIXO_REMOTO = "trade_analytics/metas"


def upload_metas(out_dir: str) -> tuple[int, int]:
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
    parser.add_argument("--out-dir", default=".", help="pasta com os CSVs (default: pasta atual)")
    parser.add_argument("--env-file", default=None, help="caminho do .env com as credenciais do Supabase (default: procura .env na pasta atual)")
    args = parser.parse_args()

    load_dotenv(dotenv_path=args.env_file)

    total_ok, total_falhou = upload_metas(args.out_dir)

    print(f"\n[resumo] ok={total_ok} | falhou={total_falhou}")
    if total_falhou > 0:
        raise SystemExit(1)
