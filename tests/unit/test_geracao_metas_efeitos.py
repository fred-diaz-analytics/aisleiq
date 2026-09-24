"""Testes unitários das metas comerciais e dos efeitos plantados no gerador
(data/lib_geracao.py).

Sem credencial, sem rede — `lib_geracao` é resolvido via `pythonpath`
configurado em pyproject.toml.
"""
from datetime import date

import pandas as pd
import pytest
from lib_geracao import (
    CATEGORIAS_LOJA,
    DIAS_DECAY_MAX,
    FATOR_PRECO_CANAL,
    K_DECAY_RUPTURA,
    N_LOJAS_CRITICAS,
    REDE_EXCELENCIA,
    REDES_GUERRA_PRECO,
    REDES_RUPTURA,
    build_baselines_marca,
    build_df_meta_share,
    build_df_perguntas,
    build_df_preco_sugerido,
    build_df_produtos,
    build_df_sku_prioridade,
    build_dim_lojas,
    build_estado_inicial,
    build_verdade_plantada,
    efeitos_loja,
    fator_decay_ruptura,
    gerar_bronze_dia_stateful,
    nota_preco,
)


@pytest.fixture(scope="module")
def dim_lojas():
    return build_dim_lojas(n_lojas=500, seed=7)


class TestMetas:
    def test_preco_sugerido_uma_linha_por_produto_canal(self):
        df = build_df_preco_sugerido()
        assert len(df) == len(build_df_produtos()) * len(CATEGORIAS_LOJA)
        assert not df.duplicated(["id_produto", "categoria_loja"]).any()

    def test_preco_sugerido_segue_fator_do_canal(self):
        df = build_df_preco_sugerido()
        baselines = build_baselines_marca(build_df_produtos()["marca"].unique().tolist())
        produtos = build_df_produtos().set_index("id_produto")
        for r in df.itertuples():
            marca = produtos.loc[r.id_produto, "marca"]
            esperado = baselines[marca]["preco_medio"] * FATOR_PRECO_CANAL[r.categoria_loja]
            # etiqueta x,x9: entre -1 e +9 centavos do valor bruto
            assert esperado - 0.011 <= r.preco_sugerido <= esperado + 0.091
            assert round(r.preco_sugerido * 100) % 10 == 9

    def test_sku_prioridade_chave_unica_e_must_have_por_categoria(self):
        df = build_df_sku_prioridade()
        assert not df.duplicated(["id_produto", "categoria_loja"]).any()
        assert (df["giro_semanal_un"] > 0).all()
        com_categoria = df.merge(build_df_produtos()[["id_produto", "categoria_produto"]], on="id_produto")
        # toda categoria tem pelo menos um must-have (os SKUs da marca líder)
        assert com_categoria.groupby("categoria_produto")["must_have"].any().all()

    def test_meta_share_chave_unica_e_no_intervalo(self):
        df = build_df_meta_share()
        assert len(df) == build_df_produtos()["id_marca"].nunique() * len(CATEGORIAS_LOJA)
        assert not df.duplicated(["id_marca", "categoria_loja"]).any()
        assert df["meta_share_pct"].between(0, 100, inclusive="right").all()


class TestEfeitosPlantados:
    def test_deterministico(self, dim_lojas):
        assert efeitos_loja(dim_lojas) == efeitos_loja(dim_lojas)

    def test_numero_de_lojas_criticas(self, dim_lojas):
        assert sum(e["critica"] for e in efeitos_loja(dim_lojas).values()) == N_LOJAS_CRITICAS

    def test_redes_plantadas_existem_no_cadastro(self, dim_lojas):
        redes = set(dim_lojas["rede"])
        assert set(REDES_RUPTURA) <= redes
        assert set(REDES_GUERRA_PRECO) <= redes
        assert REDE_EXCELENCIA in redes

    def test_efeito_aplicado_por_rede(self, dim_lojas):
        efeitos = efeitos_loja(dim_lojas)
        for loja in dim_lojas.itertuples():
            e = efeitos[loja.id_loja]
            assert (e["fator_preco"] < 1) == (loja.rede in REDES_GUERRA_PRECO)
            if loja.rede in REDES_RUPTURA:
                assert e["fator_ruptura"] > 1

    def test_decay_monotonico_e_com_teto(self):
        valores = [fator_decay_ruptura(d) for d in range(0, 60)]
        assert valores == sorted(valores)
        assert fator_decay_ruptura(0) == 0
        assert fator_decay_ruptura(DIAS_DECAY_MAX) == pytest.approx(K_DECAY_RUPTURA)
        assert fator_decay_ruptura(DIAS_DECAY_MAX + 30) == pytest.approx(K_DECAY_RUPTURA)

    def test_nota_preco_espelha_curva_sql(self):
        assert nota_preco(0.0) == 100
        assert nota_preco(-0.03) == 100
        assert nota_preco(0.05) == 100
        assert nota_preco(-0.15) == pytest.approx(36.0)
        assert nota_preco(-0.18) == pytest.approx(1.0)

    def test_verdade_plantada_ordena_severidade(self, dim_lojas):
        v = build_verdade_plantada(dim_lojas)
        assert len(v) == len(dim_lojas)
        assert v.loc[v["critica"], "severidade_esperada"].mean() > v.loc[~v["critica"], "severidade_esperada"].mean()
        assert (
            v.loc[v["rede_guerra_preco"], "severidade_esperada"].mean()
            > v.loc[~v["rede_guerra_preco"] & ~v["critica"] & ~v["rede_ruptura"], "severidade_esperada"].mean()
        )


class TestSmokeGeracao:
    def test_um_dia_de_geracao_com_efeitos(self):
        dim = build_dim_lojas(n_lojas=40, seed=7)
        df_produtos = build_df_produtos()
        baselines = build_baselines_marca(df_produtos["marca"].unique().tolist())
        estado = build_estado_inicial(dim, df_produtos, baselines)
        # segunda-feira; roda duas vezes pra garantir determinismo
        dia = date(2026, 3, 2)
        df1, estado1 = gerar_bronze_dia_stateful(dim, df_produtos, build_df_perguntas(), dia, estado.copy(), baselines)
        df2, _ = gerar_bronze_dia_stateful(dim, df_produtos, build_df_perguntas(), dia, estado.copy(), baselines)
        pd.testing.assert_frame_equal(df1, df2)
        assert len(df1) > 0
        assert set(df1["id_loja"]) <= set(dim["id_loja"])
        # estado atualizado só para as lojas visitadas
        visitadas = estado1[estado1["data_ultima_atualizacao"] == dia.isoformat()]
        assert set(visitadas["id_loja"]) == set(df1["id_loja"])
