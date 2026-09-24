"""
Deriva os CSVs do domínio `metas` (metas comerciais: preço sugerido,
prioridade de SKU, meta de share) direto das constantes do gerador
(`build_df_preco_sugerido()`/`build_df_sku_prioridade()`/`build_df_meta_share()`,
100% determinístico, sem estado de entrada — mesmo padrão de
export_dim_produto.py).

Mesma fonte de verdade que o gerador usa pra ancorar o preço observado no
PDV: meta e dado não têm como divergir.

Uso:
  python export_metas.py
  python export_metas.py --out-dir .
"""
import argparse
import os

from lib_geracao import build_df_meta_share, build_df_preco_sugerido, build_df_sku_prioridade


def export(out_dir: str) -> None:
    tabelas = {
        "preco_sugerido.csv": build_df_preco_sugerido(),
        "sku_prioridade.csv": build_df_sku_prioridade(),
        "meta_share.csv": build_df_meta_share(),
    }
    for nome, df in tabelas.items():
        df.to_csv(os.path.join(out_dir, nome), index=False)
        print(f"{nome}: {len(df)} linhas")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=".", help="pasta de saída dos CSVs")
    args = parser.parse_args()
    export(args.out_dir)
