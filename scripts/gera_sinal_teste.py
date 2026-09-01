#!/usr/bin/env python3
"""
Gera um sinal sintetico (nao ha serie temporal real disponivel nesta sessao
- o .pt do cacheTeste ja e a matriz de conectividade, nao a serie temporal
bruta que o filtro precisa) e as janelas deslizantes de entrada para testar
o filtro FIR no hardware.

O sinal combina 3 componentes de frequencia conhecida, para que a acao do
filtro seja verificavel: um drift lento (<corte inferior, deve ser
cortado), uma oscilacao dentro da banda passante (deve sobreviver), e
ruido de alta frequencia (>corte superior, deve ser cortado).

Uso:
    python3 gera_sinal_teste.py <pesos.hex> <pasta_saida>
"""
import argparse
import os
import re

import numpy as np
from scipy import signal

N_ROM = 1024
NUMTAPS = 127
TR_ASSUMIDO = 2.0
N_AMOSTRAS = 250
SEED = 42
ESCALA_X = 2**24


def le_cabecalho(caminho_hex):
    """Le corte_alto/corte_baixo/escala do cabecalho do pesos_modelo.hex
    gerado por projeta_filtro_fir.py, para nunca desalinhar com o filtro
    que realmente foi gravado na ROM."""
    with open(caminho_hex) as f:
        linhas = [l for l in f if l.startswith("//")]
    texto = "".join(linhas)
    high = float(re.search(r"high_pass=([\d.]+)", texto).group(1))
    low = float(re.search(r"low_pass=([\d.]+)", texto).group(1))
    escala_h = 2 ** int(re.search(r"2\^(\d+)", [l for l in linhas if "Ponto fixo" in l][0]).group(1))
    return high, low, escala_h


def to_hex32(v):
    return format(int(v) & 0xFFFFFFFF, "08x")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pesos_hex", help="parte_hardware/weights/pesos_modelo.hex (ja gerado)")
    ap.add_argument("pasta_saida", help="pasta onde escrever os .hex das janelas")
    args = ap.parse_args()

    corte_alto, corte_baixo, _ = le_cabecalho(args.pesos_hex)
    fs = 1.0 / TR_ASSUMIDO
    taps = signal.firwin(NUMTAPS, [corte_alto, corte_baixo], pass_zero=False,
                          fs=fs, window="hamming")

    t = np.arange(N_AMOSTRAS) * TR_ASSUMIDO
    rng = np.random.default_rng(SEED)
    drift = 0.8 * np.sin(2 * np.pi * 0.002 * t) + 0.3 * (t / t[-1])
    sinal_interesse = 1.0 * np.sin(2 * np.pi * 0.04 * t + 0.3)
    ruido_alto = 0.6 * np.sin(2 * np.pi * 0.2 * t) + rng.normal(0, 0.15, N_AMOSTRAS)
    x = drift + sinal_interesse + ruido_alto

    # Validacao empirica da convencao de janela contra scipy antes de gerar
    # qualquer arquivo (evita o tipo de erro de indexacao ja visto nesta sessao).
    y_scipy = signal.lfilter(taps, [1.0], x)
    n_teste = NUMTAPS + 5
    janela_teste = x[n_teste - NUMTAPS + 1: n_teste + 1][::-1]
    diff = abs(np.dot(taps, janela_teste) - y_scipy[n_teste])
    assert diff < 1e-9, f"Convencao de janela nao bate com scipy (diff={diff})"

    os.makedirs(args.pasta_saida, exist_ok=True)
    x_int_full = np.round(x * ESCALA_X).astype(np.int64)
    if np.abs(x_int_full).max() >= 2**31:
        raise SystemExit("ERRO: estouro de int32 no sinal")

    n = 0
    for saida_idx in range(NUMTAPS - 1, len(x), 2):
        janela = x_int_full[saida_idx - NUMTAPS + 1: saida_idx + 1][::-1]
        janela_padded = np.zeros(N_ROM, dtype=np.int64)
        janela_padded[:NUMTAPS] = janela
        nome = f"janela_n{saida_idx:04d}"
        with open(os.path.join(args.pasta_saida, f"{nome}.hex"), "w") as f:
            f.write(f"// Sinal sintetico (drift + sinal 0.04Hz + ruido), janela terminando "
                    f"na amostra {saida_idx} (t={saida_idx*TR_ASSUMIDO:.0f}s)\n")
            f.write(f"// Gerado com seed={SEED} - reproduzivel via gera_sinal_teste.py\n")
            f.write(f"// Ponto fixo: valor_inteiro = round(valor_real * 2^{ESCALA_X.bit_length()-1})\n")
            f.write(f"// referencia_float64={y_scipy[saida_idx]:.10f}\n")
            for v in janela_padded:
                f.write(to_hex32(v) + "\n")
        n += 1

    print(f"Geradas {n} janelas em {args.pasta_saida}/ (validacao contra scipy: diff={diff:.2e})")


if __name__ == "__main__":
    main()
