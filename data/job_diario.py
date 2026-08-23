"""
Job diário unificado. Toda a lógica de geração mora em lib_geracao.py — este
script é só o entrypoint (equivalente a uma Task do Databricks Job).

Uso:
  python job_diario.py --dominio todos                    # catch-up: gera todo dia útil
                                                            # faltante desde o último já
                                                            # gerado até hoje (pulando fds)
  python job_diario.py --dominio execucao --data 2026-08-12  # um dia específico só
  python job_diario.py --dominio atendimento --data 2026-08-12

Sem --data: modo catch-up (pensado pra rodar via agendador/Task Scheduler
sem se preocupar se algum dia ficou sem rodar -- detecta o último parquet
existente em <out-dir>/execucao_pdv e <out-dir>/atendimento e preenche
todo dia útil faltante até hoje, em ordem). Com --data: gera só aquele dia
(útil pra backfill manual de uma data específica).

--proximo-id-execucao/--proximo-id-atendimento são opcionais -- por padrão
o próximo id é autodetectado a partir dos parquet já existentes em
<out-dir>/execucao_pdv e <out-dir>/atendimento (só passe explicitamente se
quiser forçar um valor específico).
"""
import argparse
import glob
import os
from datetime import date, timedelta

import pandas as pd
from dotenv import load_dotenv
from lib_geracao import (
    build_baselines_marca,
    build_df_perguntas,
    build_df_produtos,
    enviar_supabase,
    gerar_atendimento_dia_stateful,
    gerar_bronze_dia_stateful,
)

OUT_DIR = "."  # sobrescrito por --out-dir


def dclientes_path(out_dir: str) -> str:
    return os.path.join(out_dir, "dclientes.csv")


def estado_execucao_path(out_dir: str) -> str:
    return os.path.join(out_dir, "estado_execucao.csv")


def estado_atendimento_path(out_dir: str) -> str:
    return os.path.join(out_dir, "estado_atendimento.csv")


def ultima_data_gerada(dias_dir: str):
    """Data (date) do parquet mais recente em dias_dir, ou None se a pasta
    ainda não tem nenhum arquivo (primeira execução)."""
    arquivos = glob.glob(os.path.join(dias_dir, "*.parquet"))
    if not arquivos:
        return None
    nome = max(os.path.basename(f)[:8] for f in arquivos)
    return date(int(nome[0:4]), int(nome[4:6]), int(nome[6:8]))


def dias_uteis_faltantes(ultima, ate: date) -> list:
    """Dias úteis (seg-sex) entre `ultima` (exclusive) e `ate` (inclusive) --
    é o catch-up: cobre o caso do job não ter rodado num dia (ou vários).
    Sem histórico ainda (`ultima=None`), devolve só [ate] (comportamento de
    gerar um único dia, igual antes)."""
    if ultima is None:
        return [ate]
    datas = []
    d = ultima + timedelta(days=1)
    while d <= ate:
        if d.weekday() < 5:  # sem visita em fim de semana, mesma regra de lojas_do_dia
            datas.append(d)
        d += timedelta(days=1)
    return datas


def proximo_id_livre(dias_dir: str) -> int:
    """Detecta o próximo id_pesquisa_resposta livre a partir dos parquet já
    existentes em <out_dir>/<execucao_pdv|atendimento> -- evita depender de
    quem chama o script rastrear e passar o id certo manualmente (fácil de
    esquecer/errar e colidir com o histórico do backfill). 1 se a pasta
    ainda não tem nenhum arquivo (primeira execução)."""
    arquivos = glob.glob(os.path.join(dias_dir, "*.parquet"))
    if not arquivos:
        return 1
    maior = max(pd.read_parquet(f, columns=["id_pesquisa_resposta"])["id_pesquisa_resposta"].max() for f in arquivos)
    return int(maior) + 1


def rodar_execucao(dim_lojas: pd.DataFrame, data_ref: date, proximo_id: int, out_dir: str, upload: bool) -> None:
    estado = pd.read_csv(estado_execucao_path(out_dir))
    df_produtos = build_df_produtos()
    df_perguntas = build_df_perguntas()
    baselines_marca = build_baselines_marca(df_produtos["marca"].unique().tolist())

    df_dia, estado_novo = gerar_bronze_dia_stateful(dim_lojas, df_produtos, df_perguntas, data_ref, estado, baselines_marca, id_inicial=proximo_id)

    nome_arquivo = f"{data_ref.strftime('%Y%m%d')}_execucao_pdv_bronze_synth.parquet"
    dias_dir = os.path.join(out_dir, "execucao_pdv")
    os.makedirs(dias_dir, exist_ok=True)
    path = os.path.join(dias_dir, nome_arquivo)
    df_dia.to_parquet(path, index=False)
    estado_novo.to_csv(estado_execucao_path(out_dir), index=False, encoding="utf-8-sig")

    n_lojas = df_dia["id_loja"].nunique() if len(df_dia) else 0
    print(f"[execucao]   {data_ref}: {len(df_dia)} linhas, {n_lojas} lojas -> {path}")

    if upload:
        remoto = f"trade_analytics/execucao_pdv/{nome_arquivo}"
        enviar_supabase(path, remoto)
        print(f"[execucao]   enviado -> supabase://datalake/{remoto}")


def rodar_atendimento(dim_lojas: pd.DataFrame, data_ref: date, proximo_id: int, out_dir: str, upload: bool) -> None:
    estado = pd.read_csv(estado_atendimento_path(out_dir))

    df_dia, estado_novo = gerar_atendimento_dia_stateful(dim_lojas, data_ref, estado, id_inicial=proximo_id)

    nome_arquivo = f"{data_ref.strftime('%Y%m%d')}_atendimento_synth.parquet"
    dias_dir = os.path.join(out_dir, "atendimento")
    os.makedirs(dias_dir, exist_ok=True)
    path = os.path.join(dias_dir, nome_arquivo)
    df_dia.to_parquet(path, index=False)
    estado_novo.to_csv(estado_atendimento_path(out_dir), index=False, encoding="utf-8-sig")

    print(f"[atendimento] {data_ref}: {len(df_dia)} visitas -> {path}")

    if upload:
        remoto = f"trade_analytics/atendimento/{nome_arquivo}"
        enviar_supabase(path, remoto)
        print(f"[atendimento] enviado -> supabase://datalake/{remoto}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--dominio", choices=["execucao", "atendimento", "todos"], default="todos")
    parser.add_argument("--data", default=None, help="YYYY-MM-DD (default: hoje)")
    parser.add_argument("--proximo-id-execucao", type=int, default=None, help="default: autodetectado a partir do maior id_pesquisa_resposta já existente em <out-dir>/execucao_pdv")
    parser.add_argument("--proximo-id-atendimento", type=int, default=None, help="default: autodetectado a partir do maior id_pesquisa_resposta já existente em <out-dir>/atendimento")
    parser.add_argument("--out-dir", default=OUT_DIR, help="diretório com dclientes.csv/estado_*.csv; os arquivos do dia vão para <out-dir>/execucao_pdv e <out-dir>/atendimento")
    parser.add_argument("--upload-supabase", action="store_true", help="depois de gerar, sobe o arquivo pro Supabase Storage (requer variáveis de ambiente SUPABASE_*)")
    parser.add_argument("--env-file", default=None, help="caminho do .env com as credenciais do Supabase (default: procura .env na pasta atual)")
    args = parser.parse_args()

    load_dotenv(dotenv_path=args.env_file)  # se --env-file não for passado, cai no comportamento padrão (.env na pasta atual)

    dim_lojas = pd.read_csv(dclientes_path(args.out_dir))  # dclientes: única para os dois domínios, só lida
    hoje = date.today()

    if args.dominio in ("execucao", "todos"):
        dias_dir_execucao = os.path.join(args.out_dir, "execucao_pdv")
        datas_execucao = [date.fromisoformat(args.data)] if args.data else dias_uteis_faltantes(ultima_data_gerada(dias_dir_execucao), hoje)
        if args.data is None and len(datas_execucao) > 1:
            print(f"[execucao]   catch-up: {len(datas_execucao)} dia(s) faltando ({datas_execucao[0]} a {datas_execucao[-1]})")
        for data_ref in datas_execucao:
            proximo_execucao = args.proximo_id_execucao if args.proximo_id_execucao is not None else proximo_id_livre(dias_dir_execucao)
            rodar_execucao(dim_lojas, data_ref, proximo_execucao, args.out_dir, args.upload_supabase)

    if args.dominio in ("atendimento", "todos"):
        dias_dir_atendimento = os.path.join(args.out_dir, "atendimento")
        datas_atendimento = [date.fromisoformat(args.data)] if args.data else dias_uteis_faltantes(ultima_data_gerada(dias_dir_atendimento), hoje)
        if args.data is None and len(datas_atendimento) > 1:
            print(f"[atendimento] catch-up: {len(datas_atendimento)} dia(s) faltando ({datas_atendimento[0]} a {datas_atendimento[-1]})")
        for data_ref in datas_atendimento:
            proximo_atendimento = args.proximo_id_atendimento if args.proximo_id_atendimento is not None else proximo_id_livre(dias_dir_atendimento)
            rodar_atendimento(dim_lojas, data_ref, proximo_atendimento, args.out_dir, args.upload_supabase)