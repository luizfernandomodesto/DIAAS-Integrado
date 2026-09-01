#!/usr/bin/env python3
"""
Projeta o filtro FIR temporal (a etapa que a Proposta_Hardware.pdf pede:
"o filtro temporal (filtro FIR)") a partir das frequencias de corte REAIS
usadas no pre-processamento do Thiago - extraidas diretamente de
parte_software/preProcessamento.py (regex em low_pass=/high_pass=), nao
digitadas a mao, para nunca divergir se esses valores mudarem.

O pipeline real do Thiago filtra com um Butterworth (IIR) de parametros
fixos, dentro do NiftiLabelsMasker. Este script projeta um FIR (janela de
Hamming) que aproxima a MESMA faixa de passagem - FIR e mais adequado pra
implementacao em hardware (estavel, sem realimentacao, direto pra um
pipeline de MAC).

Gera parte_hardware/weights/pesos_modelo.hex: os 127 coeficientes reais,
convertidos para ponto fixo, zero-padded ate 1024 (profundidade da ROM).

Uso:
    python3 projeta_filtro_fir.py <preProcessamento.py> <pasta_saida_hw>
"""
import argparse
import math
import os
import re

import numpy as np
from scipy import signal

N_ROM = 1024
NUMTAPS = 127          # ordem escolhida empiricamente
TR_ASSUMIDO = 2.0       # segundos - TR real varia por site no ABIDE; 2.0s
                         # e o valor mais comum em fMRI de repouso


def extrai_cortes(caminho_preprocessamento):
    """Retorna (high_pass, low_pass) em Hz, lidos direto do arquivo real."""
    with open(caminho_preprocessamento, encoding="utf-8") as f:
        codigo = f.read()
    m_low = re.search(r"low_pass\s*=\s*([\d.]+)", codigo)
    m_high = re.search(r"high_pass\s*=\s*([\d.]+)", codigo)
    if not m_low or not m_high:
        raise ValueError(f"Nao achei low_pass=/high_pass= em {caminho_preprocessamento}")
    return float(m_high.group(1)), float(m_low.group(1))


def escolhe_escala(pesos_float):
    max_abs = float(np.abs(pesos_float).max())
    if max_abs == 0:
        return 2**28
    bits_livres = 31 - 2
    expoente = bits_livres - math.ceil(math.log2(max_abs))
    return 2 ** max(1, expoente)


def to_hex32(v):
    return format(int(v) & 0xFFFFFFFF, "08x")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("preprocessamento_py", help="parte_software/preProcessamento.py")
    ap.add_argument("pasta_saida_hw", help="parte_hardware (onde escrever weights/pesos_modelo.hex)")
    args = ap.parse_args()

    corte_alto, corte_baixo = extrai_cortes(args.preprocessamento_py)  # (high_pass, low_pass)
    fs = 1.0 / TR_ASSUMIDO
    taps = signal.firwin(NUMTAPS, [corte_alto, corte_baixo], pass_zero=False,
                          fs=fs, window="hamming")

    escala = escolhe_escala(taps)
    h_int = np.round(taps * escala).astype(np.int64)
    if np.abs(h_int).max() >= 2**31:
        raise SystemExit(f"ERRO: estouro de int32 com escala=2^{escala.bit_length()-1}")

    h_padded = np.zeros(N_ROM, dtype=np.int64)
    h_padded[:NUMTAPS] = h_int

    pasta_pesos = os.path.join(args.pasta_saida_hw, "weights")
    os.makedirs(pasta_pesos, exist_ok=True)
    caminho_saida = os.path.join(pasta_pesos, "pesos_modelo.hex")
    with open(caminho_saida, "w") as f:
        f.write(f"// Filtro FIR temporal, {NUMTAPS} taps (janela de Hamming).\n")
        f.write(f"// Frequencias de corte extraidas de {os.path.basename(args.preprocessamento_py)}: "
                f"high_pass={corte_alto} Hz, low_pass={corte_baixo} Hz.\n")
        f.write(f"// TR assumido={TR_ASSUMIDO}s (fs={fs}Hz) - TR real varia por site no ABIDE.\n")
        f.write(f"// Ponto fixo: valor_inteiro = round(valor_real * 2^{escala.bit_length()-1}).\n")
        f.write(f"// Posicoes {NUMTAPS}..{N_ROM-1} = 0 (zero-padding ate a profundidade da ROM).\n")
        for v in h_padded:
            f.write(to_hex32(v) + "\n")

    print(f"Gerado: {caminho_saida} ({NUMTAPS} taps reais + zero-padding, "
          f"cortes {corte_alto}-{corte_baixo}Hz, escala=2^{escala.bit_length()-1})")


if __name__ == "__main__":
    main()
