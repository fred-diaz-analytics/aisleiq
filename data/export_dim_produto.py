"""
Deriva os CSVs normalizados do domínio `produtos` a partir do catálogo do
gerador (`build_df_produtos()`, 100% determinístico, sem estado persistido
de entrada, diferente de `export_dim_loja.py`/`dclientes.csv`).

`categoria_produto` vira sua própria tabela mestre (`categorias.csv`), igual
`categorias_loja` no domínio `lojas`. `marca` fica embutida em `produtos.csv`
(nome + `id_marca` juntos): diferente de categoria, marca nunca teve vida
própria como cadastro no sistema simulado, só é atributo do produto.

Uso:
  python export_dim_produto.py
  python export_dim_produto.py --out-dir .
"""
import argparse
import os

from lib_geracao import build_df_produtos


def export(out_dir: str) -> None:
    df = build_df_produtos()

    categorias = (
        df[["id_categoria", "categoria_produto"]]
        .drop_duplicates()
        .sort_values("id_categoria")
        .reset_index(drop=True)
    )
    categorias.to_csv(os.path.join(out_dir, "categorias.csv"), index=False)

    produtos = df[["id_produto", "produto", "tamanho", "id_marca", "marca", "id_categoria"]]
    produtos.to_csv(os.path.join(out_dir, "produtos.csv"), index=False)

    print(f"categorias.csv: {len(categorias)} linhas")
    print(f"produtos.csv: {len(produtos)} linhas")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default=".", help="pasta de saída dos CSVs")
    args = parser.parse_args()
    export(args.out_dir)
