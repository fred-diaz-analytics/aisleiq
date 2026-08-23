"""Testes unitários da lógica pura de ingestão bronze (bronze_lib.py).

Sem credencial, sem rede, sem cluster — rodam em qualquer máquina/CI.
`bronze_lib` é resolvido via `pythonpath` configurado em pyproject.toml.
"""
from datetime import date

import pytest
from bronze_lib import match_candidate_files, parse_source_date


class TestParseSourceDate:
    def test_formato_valido(self):
        assert parse_source_date("20260115") == date(2026, 1, 15)

    def test_formato_invalido_levanta_erro(self):
        with pytest.raises(ValueError):
            parse_source_date("2026-01-15")

    def test_string_vazia_levanta_erro(self):
        with pytest.raises(ValueError):
            parse_source_date("")


class TestMatchCandidateFiles:
    FILE_REGEX = r"(\d{8}).*execucao_pdv.*\.parquet$"

    def test_bate_padrao_e_extrai_data(self):
        keys = ["trade_analytics/execucao_pdv/20260101_execucao_pdv_bronze_synth.parquet"]
        out = match_candidate_files(keys, self.FILE_REGEX, "19000101")
        assert len(out) == 1
        assert out[0]["date_str"] == "20260101"
        assert out[0]["name"] == "20260101_execucao_pdv_bronze_synth.parquet"
        assert out[0]["key"] == keys[0]

    def test_ignora_arquivo_que_nao_bate_no_regex(self):
        keys = [
            "trade_analytics/execucao_pdv/20260101_execucao_pdv_bronze_synth.parquet",
            "trade_analytics/execucao_pdv/README.md",
            "trade_analytics/execucao_pdv/20260101_atendimento_synth.parquet",  # domínio errado
        ]
        out = match_candidate_files(keys, self.FILE_REGEX, "19000101")
        assert len(out) == 1
        assert out[0]["name"] == "20260101_execucao_pdv_bronze_synth.parquet"

    def test_filtra_por_cutoff_watermark(self):
        keys = [
            "p/20260101_execucao_pdv_bronze_synth.parquet",
            "p/20260105_execucao_pdv_bronze_synth.parquet",
            "p/20260110_execucao_pdv_bronze_synth.parquet",
        ]
        out = match_candidate_files(keys, self.FILE_REGEX, "20260105")
        dates = [f["date_str"] for f in out]
        assert dates == ["20260105", "20260110"]

    def test_ordena_por_data_ascendente(self):
        keys = [
            "p/20260110_execucao_pdv_bronze_synth.parquet",
            "p/20260101_execucao_pdv_bronze_synth.parquet",
            "p/20260105_execucao_pdv_bronze_synth.parquet",
        ]
        out = match_candidate_files(keys, self.FILE_REGEX, "19000101")
        assert [f["date_str"] for f in out] == ["20260101", "20260105", "20260110"]

    def test_lista_vazia_retorna_lista_vazia(self):
        assert match_candidate_files([], self.FILE_REGEX, "19000101") == []

    def test_regex_atendimento_nao_bate_arquivo_execucao(self):
        atendimento_regex = r"(\d{8}).*atendimento.*\.parquet$"
        keys = ["p/20260101_execucao_pdv_bronze_synth.parquet"]
        assert match_candidate_files(keys, atendimento_regex, "19000101") == []
