#!/usr/bin/env python3
import argparse
import ast
import os
import numpy as np
import torch
import torch.nn as nn


def extrai_classe(caminho_arquivo, nome_classe):
    with open(caminho_arquivo, encoding="utf-8") as f:
        codigo_fonte = f.read()
    arvore = ast.parse(codigo_fonte)
    for node in arvore.body:
        if isinstance(node, ast.ClassDef) and node.name == nome_classe:
            return ast.get_source_segment(codigo_fonte, node)
    raise ValueError(f"Classe {nome_classe} nao encontrada em {caminho_arquivo}")


CAMINHO_LOOPTREINO_ORIGINAL = os.path.join(
    os.path.dirname(__file__), "..", "parte_software", "loopTreino.py"
)
_codigo_classe = extrai_classe(CAMINHO_LOOPTREINO_ORIGINAL, "FCN_Apresentacao1D")
_namespace = {"nn": nn}
exec(_codigo_classe, _namespace)
FCN_Apresentacao1D = _namespace["FCN_Apresentacao1D"]


def encontra(pasta, prefixo):
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(f"Nao encontrei {prefixo}*.npy em {pasta}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("parte_software")
    ap.add_argument("saida_txt")
    args = ap.parse_args()
    tensor, label = torch.load(args.sujeito_pt, weights_only=False)
    x_bruto = tensor.numpy()
    x_bruto = np.nan_to_num(x_bruto, nan=0.0, posinf=0.0, neginf=0.0)
    indices = np.load(encontra(args.parte_software, "indices_selecionados"))
    norm_mean = np.load(encontra(args.parte_software, "norm_mean"))
    norm_std = np.load(encontra(args.parte_software, "norm_std"))
    x_final = (x_bruto[indices] - norm_mean) / norm_std
    modelo = FCN_Apresentacao1D()
    caminho_pth = os.path.join(args.parte_software, "modeloTeste")
    state_dict = torch.load(caminho_pth, map_location="cpu", weights_only=False)
    modelo.load_state_dict(state_dict)
    modelo.eval()
    x_tensor = torch.from_numpy(x_final).float().unsqueeze(0)
    with torch.no_grad():
        logits = modelo(x_tensor)
        probs = torch.softmax(logits, dim=1)[0]
    prob_controle, prob_tea = (probs[0].item(), probs[1].item())
    predicao = "TEA" if prob_tea > prob_controle else "controle"
    rotulo_real = "TEA" if label == 1 else "controle"
    with open(args.saida_txt, "w") as f:
        f.write(f"predicao={predicao}\n")
        f.write(f"prob_controle={prob_controle:.6f}\n")
        f.write(f"prob_tea={prob_tea:.6f}\n")
        f.write(f"rotulo_real={rotulo_real}\n")
        f.write(f"acertou={predicao == rotulo_real}\n")
    print(
        f"{os.path.basename(args.sujeito_pt)}: predicao={predicao} (p_tea={prob_tea:.3f}) rotulo_real={rotulo_real}"
    )


if __name__ == "__main__":
    main()
