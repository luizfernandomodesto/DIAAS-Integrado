#!/usr/bin/env python3
"""
Prepara as janelas de entrada para filtrar, NO HARDWARE, o vetor de 512
features real de um sujeito (.pt) - a mesma etapa que roda_software.py usa
como entrada do classificador, so que aqui cada uma das 512 posicoes do
vetor filtrado sera calculada por uma chamada separada ao hardware (o
acelerador so produz 1 saida por chamada).

AVISO IMPORTANTE (documentado tambem no resultado final): isso aplica o
filtro FIR sobre a ORDEM DAS 512 FEATURES SELECIONADAS PELO SelectKBest,
que e uma ordem de RELEVANCIA ESTATISTICA - nao uma ordem TEMPORAL. O
filtro original (Butterworth, dentro do NiftiLabelsMasker) atua sobre a
serie temporal bruta, ANTES da correlacao ser calculada - essa etapa nao
esta disponivel nesta sessao (nao ha imagem fMRI bruta). O que segue e uma
integracao MECANICA hardware->software (o numero que sai do hardware vira
a entrada do classificador), pedida explicitamente para demonstrar a
integracao do pipeline - nao uma reproducao cientifica do pre-processamento
temporal real.

Uso:
    python3 prepara_filtragem_pt.py <sujeito.pt> <parte_software> <pesos.hex> <pasta_saida>
"""
import argparse
import os
import re

import numpy as np
import torch

N_ROM = 1024
NUMTAPS = 127
ESCALA_X = 2**24


def encontra(pasta, prefixo):
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(prefixo)


def le_vetor_real(caminho_pt, parte_software_dir):
    tensor, label = torch.load(caminho_pt, weights_only=False)
    x_bruto = np.nan_to_num(tensor.numpy(), nan=0.0, posinf=0.0, neginf=0.0)
    indices = np.load(encontra(parte_software_dir, "indices_selecionados"))
    norm_mean = np.load(encontra(parte_software_dir, "norm_mean"))
    norm_std = np.load(encontra(parte_software_dir, "norm_std"))
    x_final = (x_bruto[indices] - norm_mean) / norm_std
    return x_final, label


def to_hex32(v):
    return format(int(v) & 0xFFFFFFFF, "08x")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("parte_software")
    ap.add_argument("pesos_hex", help="parte_hardware/weights/pesos_modelo.hex (o filtro ja projetado)")
    ap.add_argument("pasta_saida")
    args = ap.parse_args()

    x, label = le_vetor_real(args.sujeito_pt, args.parte_software)
    n = len(x)  # 512

    x_int = np.round(x * ESCALA_X).astype(np.int64)
    if np.abs(x_int).max() >= 2**31:
        raise SystemExit("ERRO: estouro de int32")

    # Zero-padding a ESQUERDA (amostras "antes" da posicao 0, para o filtro
    # causal ter o que consumir nas primeiras saidas - mesma convencao "same"
    # do scipy.signal.lfilter, ja validada nesta sessao).
    x_estendido = np.concatenate([np.zeros(NUMTAPS - 1, dtype=np.int64), x_int])

    os.makedirs(args.pasta_saida, exist_ok=True)
    nomes = []
    for saida_idx in range(n):
        # janela = x[idx], x[idx-1], ..., x[idx-126], em unidades do array
        # estendido: posicao (saida_idx + NUMTAPS - 1) e o "presente"
        fim = saida_idx + NUMTAPS
        janela = x_estendido[saida_idx:fim][::-1]
        janela_padded = np.zeros(N_ROM, dtype=np.int64)
        janela_padded[:NUMTAPS] = janela
        nome = f"pos_{saida_idx:03d}"
        with open(os.path.join(args.pasta_saida, f"{nome}.hex"), "w") as f:
            f.write(f"// Janela para a posicao {saida_idx} do vetor filtrado (ver AVISO em "
                     "prepara_filtragem_pt.py: filtro aplicado sobre ordem de relevancia\n")
            f.write("// estatistica do SelectKBest, nao ordem temporal).\n")
            f.write(f"// Ponto fixo: valor_inteiro = round(valor_real * 2^{ESCALA_X.bit_length()-1})\n")
            for v in janela_padded:
                f.write(to_hex32(v) + "\n")
        nomes.append(nome)

    print(f"Geradas {len(nomes)} janelas (posicoes 0-{n-1}) em {args.pasta_saida}/")


if __name__ == "__main__":
    main()
