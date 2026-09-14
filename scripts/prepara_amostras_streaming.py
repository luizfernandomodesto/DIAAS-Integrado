#!/usr/bin/env python3
import argparse
import os
import numpy as np
import torch

ESCALA_X = 2**24


def encontra(pasta, prefixo):
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(prefixo)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("parte_software")
    ap.add_argument("pasta_saida")
    args = ap.parse_args()
    tensor, label = torch.load(args.sujeito_pt, weights_only=False)
    x_bruto = np.nan_to_num(tensor.numpy(), nan=0.0, posinf=0.0, neginf=0.0)
    indices = np.load(encontra(args.parte_software, "indices_selecionados"))
    norm_mean = np.load(encontra(args.parte_software, "norm_mean"))
    norm_std = np.load(encontra(args.parte_software, "norm_std"))
    x = (x_bruto[indices] - norm_mean) / norm_std
    x_int = np.round(x * ESCALA_X).astype(np.int64)
    if np.abs(x_int).max() >= 2**31:
        raise SystemExit("ERRO: estouro de int32")
    os.makedirs(args.pasta_saida, exist_ok=True)
    nome = os.path.splitext(os.path.basename(args.sujeito_pt))[0]
    caminho_saida = os.path.join(args.pasta_saida, f"{nome}_amostras.hex")
    with open(caminho_saida, "w") as f:
        for v in x_int:
            f.write(format(int(v) & 4294967295, "08x") + "\n")
    print(f"Gerado: {caminho_saida} ({len(x_int)} amostras)")


if __name__ == "__main__":
    main()
