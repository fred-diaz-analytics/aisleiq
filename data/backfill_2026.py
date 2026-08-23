"""
Backfill unificado (01/01/2026 a 10/08/2026, janela fixa — não "até hoje" —
pra manter os números reproduzíveis). Mesmo padrão do job_diario.py:
entrypoint fino, toda a lógica de geração mora em lib_geracao.py.

Toda a geração é determinística (seeds amarradas à data + seed=7 fixo para
lojas/promotores), então rodar este script em qualquer máquina reproduz
exatamente os mesmos arquivos, byte a byte.

Uso:
  python backfill_2026.py --dominio todos
  python backfill_2026.py --dominio execucao
  python backfill_2026.py --dominio atendimento
  python backfill_2026.py --dominio todos --out-dir ./data
"""
import argparse
import os
from datetime import date, timedelta

import pandas as pd
from lib_geracao import (
    build_baselines_marca,
    build_df_perguntas,
    build_df_produtos,
    build_dim_lojas,
    build_estado_inicial,
    build_estado_inicial_atendimento,
    gerar_atendimento_dia_stateful,
    gerar_bronze_dia_stateful,
)

DATA_INICIO = date(2026, 1, 1)
DATA_FIM = date(2026, 8, 10)


def limpar_pasta(pasta: str) -> None:
    os.makedirs(pasta, exist_ok=True)
    for f in os.listdir(pasta):
        os.remove(os.path.join(pasta, f))


def backfill_execucao(dim_lojas: pd.DataFrame, out_dir: str) -> None:
    dias_dir = os.path.join(out_dir, "execucao_pdv")
    limpar_pasta(dias_dir)

    df_produtos = build_df_produtos()
    df_perguntas = build_df_perguntas()
    baselines_marca = build_baselines_marca(df_produtos["marca"].unique().tolist())
    estado = build_estado_inicial(dim_lojas, df_produtos, baselines_marca)

    total_dias = (DATA_FIM - DATA_INICIO).days + 1
    resumo, proximo_id, d, i = [], 1, DATA_INICIO, 0
    while d <= DATA_FIM:
        i += 1
        df_dia, estado = gerar_bronze_dia_stateful(dim_lojas, df_produtos, df_perguntas, d, estado, baselines_marca, id_inicial=proximo_id)
        if len(df_dia) > 0:
            df_dia.to_parquet(os.path.join(dias_dir, f"{d.strftime('%Y%m%d')}_execucao_pdv_bronze_synth.parquet"), index=False)
            proximo_id = int(df_dia["id_pesquisa_resposta"].max()) + 1
            resumo.append({"data": d.isoformat(), "n_lojas_visitadas": df_dia["id_loja"].nunique(), "n_linhas": len(df_dia)})
            print(f"[execucao]   ({i}/{total_dias}) {d.isoformat()}: {len(df_dia)} linhas", flush=True)
        else:
            print(f"[execucao]   ({i}/{total_dias}) {d.isoformat()}: sem visitas", flush=True)
        d += timedelta(days=1)

    pd.DataFrame(resumo).to_csv(os.path.join(out_dir, "resumo_backfill_2026.csv"), index=False, encoding="utf-8-sig")
    estado.to_csv(os.path.join(out_dir, "estado_execucao.csv"), index=False, encoding="utf-8-sig")
    print(f"[execucao]   concluído: {len(resumo)} dias com dado | próximo id livre: {proximo_id} | arquivos em {dias_dir}")


def backfill_atendimento(dim_lojas: pd.DataFrame, out_dir: str) -> None:
    dias_dir = os.path.join(out_dir, "atendimento")
    limpar_pasta(dias_dir)

    estado = build_estado_inicial_atendimento(dim_lojas)

    total_dias = (DATA_FIM - DATA_INICIO).days + 1
    resumo, proximo_id, d, i = [], 1, DATA_INICIO, 0
    while d <= DATA_FIM:
        i += 1
        df_dia, estado = gerar_atendimento_dia_stateful(dim_lojas, d, estado, id_inicial=proximo_id)
        if len(df_dia) > 0:
            df_dia.to_parquet(os.path.join(dias_dir, f"{d.strftime('%Y%m%d')}_atendimento_synth.parquet"), index=False)
            proximo_id = int(df_dia["id_pesquisa_resposta"].max()) + 1
            resumo.append({
                "data": d.isoformat(), "n_lojas_visitadas": df_dia["id_loja"].nunique(),
                "n_ok": (df_dia["atendimento"] == "OK").sum(),
                "n_np": (df_dia["atendimento"] == "NP").sum(),
                "n_x": (df_dia["atendimento"] == "X").sum(),
            })
            print(f"[atendimento] ({i}/{total_dias}) {d.isoformat()}: {len(df_dia)} visitas", flush=True)
        else:
            print(f"[atendimento] ({i}/{total_dias}) {d.isoformat()}: sem visitas", flush=True)
        d += timedelta(days=1)

    pd.DataFrame(resumo).to_csv(os.path.join(out_dir, "resumo_backfill_atendimento_2026.csv"), index=False, encoding="utf-8-sig")
    estado.to_csv(os.path.join(out_dir, "estado_atendimento.csv"), index=False, encoding="utf-8-sig")
    print(f"[atendimento] concluído: {len(resumo)} dias com dado | próximo id livre: {proximo_id} | arquivos em {dias_dir}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dominio", choices=["execucao", "atendimento", "todos"], default="todos")
    parser.add_argument("--n-lojas", type=int, default=500)
    parser.add_argument("--out-dir", default=".", help="diretório de saída — recebe dclientes.csv/estado_*.csv e as subpastas execucao_pdv/ e atendimento/ (default: pasta atual)")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    print(f"Gerando dimensão de lojas ({args.n_lojas} lojas)...", flush=True)
    dim_lojas = build_dim_lojas(n_lojas=args.n_lojas, seed=7)  # dclientes: gerada uma vez, serve os dois domínios
    dim_lojas.to_csv(os.path.join(args.out_dir, "dclientes.csv"), index=False, encoding="utf-8-sig")
    print("dclientes.csv pronto.\n", flush=True)

    if args.dominio in ("execucao", "todos"):
        print(f"=== Backfill execução PDV: {DATA_INICIO.isoformat()} a {DATA_FIM.isoformat()} ===", flush=True)
        backfill_execucao(dim_lojas, args.out_dir)
    if args.dominio in ("atendimento", "todos"):
        print(f"\n=== Backfill atendimento: {DATA_INICIO.isoformat()} a {DATA_FIM.isoformat()} ===", flush=True)
        backfill_atendimento(dim_lojas, args.out_dir)
