"""
Exporta o gabarito dos efeitos plantados pelo gerador
(`build_verdade_plantada()` em lib_geracao.py): por loja, quais efeitos
foram plantados (rede com ruptura, guerra de preço, rede de excelência,
loja crítica, cadência) e a severidade esperada em pontos de score.

NÃO é dado de negócio e NÃO vai pro lakehouse pela pipeline: é a chave de
resposta usada só pra validar se o score reencontra o que foi plantado
(src/analysis/validar_verdade_plantada.py). Gitignored, reproduzível.

Uso:
  python export_verdade_plantada.py
  python export_verdade_plantada.py --dclientes dclientes.csv --out-dir .
"""
import argparse
import os

import pandas as pd
from lib_geracao import build_verdade_plantada


def export(dclientes_path: str, out_dir: str) -> None:
    df = build_verdade_plantada(pd.read_csv(dclientes_path))
    df.to_csv(os.path.join(out_dir, "verdade_plantada.csv"), index=False)
    print(f"verdade_plantada.csv: {len(df)} lojas | críticas={int(df['critica'].sum())}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dclientes", default="dclientes.csv", help="caminho do dclientes.csv (estado interno do gerador)")
    parser.add_argument("--out-dir", default=".", help="pasta de saída")
    args = parser.parse_args()
    export(args.dclientes, args.out_dir)
