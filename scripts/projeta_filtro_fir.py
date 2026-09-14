#!/usr/bin/env python3
# Projeta o filtro FIR temporal a partir das frequências de corte reais.
import argparse
import math
import os
import re

import numpy as np
from scipy import signal

N_ROM = 1024  # profundidade da ROM de pesos no hardware
NUMTAPS = 127  # número de coeficientes do filtro
TR_ASSUMIDO = 2.0  # TR em segundos, pra converter Hz em frequência normalizada


def extrai_cortes(caminho_preprocessamento):
    # Lê high_pass e low_pass direto do preProcessamento.py real
    with open(caminho_preprocessamento, encoding="utf-8") as f:
        codigo = f.read()
    m_low = re.search("low_pass\\s*=\\s*([\\d.]+)", codigo)
    m_high = re.search("high_pass\\s*=\\s*([\\d.]+)", codigo)
    if not m_low or not m_high:
        raise ValueError(
            f"Nao achei low_pass=/high_pass= em {caminho_preprocessamento}"
        )
    return (float(m_high.group(1)), float(m_low.group(1)))


def escolhe_escala(pesos_float):
    # Acha a maior escala de ponto fixo que ainda cabe em int32
    max_abs = float(np.abs(pesos_float).max())
    if max_abs == 0:
        return 2**28
    bits_livres = 31 - 2
    expoente = bits_livres - math.ceil(math.log2(max_abs))
    return 2 ** max(1, expoente)


def to_hex32(v):
    # Formata um inteiro como hexadecimal de 32 bits
    return format(int(v) & 4294967295, "08x")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("preprocessamento_py", help="parte_software/preProcessamento.py")
    ap.add_argument(
        "pasta_saida_hw", help="parte_hardware (onde escrever weights/pesos_modelo.hex)"
    )
    args = ap.parse_args()
    corte_alto, corte_baixo = extrai_cortes(args.preprocessamento_py)

    # Projeta o filtro (janela de Hamming) nas frequências de corte reais
    fs = 1.0 / TR_ASSUMIDO
    taps = signal.firwin(
        NUMTAPS, [corte_alto, corte_baixo], pass_zero=False, fs=fs, window="hamming"
    )

    # Converte os coeficientes pra ponto fixo, do jeito que o hardware lê
    escala = escolhe_escala(taps)
    h_int = np.round(taps * escala).astype(np.int64)
    if np.abs(h_int).max() >= 2**31:
        raise SystemExit(
            f"ERRO: estouro de int32 com escala=2^{escala.bit_length() - 1}"
        )

    # Completa com zero até a profundidade da ROM
    h_padded = np.zeros(N_ROM, dtype=np.int64)
    h_padded[:NUMTAPS] = h_int

    # Escreve o .hex, com um cabeçalho explicando os taps e a escala usada
    pasta_pesos = os.path.join(args.pasta_saida_hw, "weights")
    os.makedirs(pasta_pesos, exist_ok=True)
    caminho_saida = os.path.join(pasta_pesos, "pesos_modelo.hex")
    with open(caminho_saida, "w") as f:
        f.write(f"// Filtro FIR temporal, {NUMTAPS} taps (janela de Hamming).\n")
        f.write(
            f"// Frequencias de corte extraidas de {os.path.basename(args.preprocessamento_py)}: high_pass={corte_alto} Hz, low_pass={corte_baixo} Hz.\n"
        )
        f.write(
            f"// TR assumido={TR_ASSUMIDO}s (fs={fs}Hz) - TR real varia por site no ABIDE.\n"
        )
        f.write(
            f"// Ponto fixo: valor_inteiro = round(valor_real * 2^{escala.bit_length() - 1}).\n"
        )
        f.write(
            f"// Posicoes {NUMTAPS}..{N_ROM - 1} = 0 (zero-padding ate a profundidade da ROM).\n"
        )
        for v in h_padded:
            f.write(to_hex32(v) + "\n")
    print(
        f"Gerado: {caminho_saida} ({NUMTAPS} taps reais + zero-padding, cortes {corte_alto}-{corte_baixo}Hz, escala=2^{escala.bit_length() - 1})"
    )


if __name__ == "__main__":
    main()
