"""
Deriva os 5 CSVs normalizados (snowflake) do domínio `lojas` a partir do
estado interno do gerador (data/dclientes.csv).

Não altera dclientes.csv (continua servindo só pra continuidade do
gerador entre execuções do job_diario.py). As saídas aqui são dado
público do projeto, pensadas pra ingestão real (bronze/silver/gold).

Uso:
  python export_dim_loja.py
  python export_dim_loja.py --dclientes dclientes.csv --out-dir .
"""
import argparse
import os

import pandas as pd

UF_PARA_NOME_ESTADO = {
    "AC": "Acre", "AL": "Alagoas", "AP": "Amapá", "AM": "Amazonas", "BA": "Bahia",
    "CE": "Ceará", "DF": "Distrito Federal", "ES": "Espírito Santo", "GO": "Goiás",
    "MA": "Maranhão", "MT": "Mato Grosso", "MS": "Mato Grosso do Sul", "MG": "Minas Gerais",
    "PA": "Pará", "PB": "Paraíba", "PR": "Paraná", "PE": "Pernambuco", "PI": "Piauí",
    "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte", "RS": "Rio Grande do Sul",
    "RO": "Rondônia", "RR": "Roraima", "SC": "Santa Catarina", "SP": "São Paulo",
    "SE": "Sergipe", "TO": "Tocantins",
}

CATEGORIAS_LOJA = ["VAREJO", "ATACADO", "ATACAREJO"]


def export(dclientes_path: str, out_dir: str) -> None:
    df = pd.read_csv(dclientes_path)

    estados = df[["uf", "regiao"]].drop_duplicates().sort_values("uf").reset_index(drop=True)
    estados["nome_estado"] = estados["uf"].map(UF_PARA_NOME_ESTADO)
    estados = estados[["uf", "nome_estado", "regiao"]]
    estados.to_csv(os.path.join(out_dir, "estados.csv"), index=False)

    cidades = df[["cidade", "uf"]].drop_duplicates().sort_values(["uf", "cidade"]).reset_index(drop=True)
    cidades.insert(0, "id_cidade", cidades.index + 1)
    cidades.to_csv(os.path.join(out_dir, "cidades.csv"), index=False)

    categorias_loja = pd.DataFrame({
        "id_categoria_loja": range(1, len(CATEGORIAS_LOJA) + 1),
        "categoria_loja": CATEGORIAS_LOJA,
    })
    categorias_loja.to_csv(os.path.join(out_dir, "categorias_loja.csv"), index=False)

    redes = df[["rede"]].drop_duplicates().sort_values("rede").reset_index(drop=True)
    redes.insert(0, "id_rede", redes.index + 1)
    redes = redes.rename(columns={"rede": "nome_rede"})
    redes.to_csv(os.path.join(out_dir, "redes.csv"), index=False)

    lojas = df.merge(cidades, on=["cidade", "uf"], how="left")
    lojas = lojas.merge(categorias_loja, on="categoria_loja", how="left")
    lojas = lojas.merge(redes, left_on="rede", right_on="nome_rede", how="left")
    lojas = lojas[["id_loja", "nome_fantasia", "endereco", "id_cidade", "id_categoria_loja", "id_rede"]]
    lojas.to_csv(os.path.join(out_dir, "lojas.csv"), index=False)

    print(f"estados.csv: {len(estados)} linhas")
    print(f"cidades.csv: {len(cidades)} linhas")
    print(f"categorias_loja.csv: {len(categorias_loja)} linhas")
    print(f"redes.csv: {len(redes)} linhas")
    print(f"lojas.csv: {len(lojas)} linhas")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dclientes", default="dclientes.csv", help="caminho do dclientes.csv (estado interno do gerador)")
    parser.add_argument("--out-dir", default=".", help="pasta de saída dos 5 CSVs")
    args = parser.parse_args()
    export(args.dclientes, args.out_dir)
