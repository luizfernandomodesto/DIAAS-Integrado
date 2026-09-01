#!/usr/bin/env python3
"""
Reconstroi o vetor de 512 features FILTRADO (uma posicao por chamada de
hardware, ja rodadas) e roda o classificador REAL do Thiago nele - depois
compara com a predicao SEM filtro (o baseline que roda_software.py ja
calcula), sobre o MESMO sujeito.

AVISO (repetido do prepara_filtragem_pt.py): o filtro foi aplicado sobre a
ordem das 512 features selecionadas pelo SelectKBest (relevancia
estatistica), nao sobre uma serie temporal real - nao ha imagem fMRI bruta
disponivel nesta sessao para fazer a filtragem temporal cientificamente
correta. Isto e uma integracao MECANICA hardware->software, para demonstrar
o pipeline completo, nao uma validacao cientifica de que o filtro melhora
a classificacao.

Uso:
    python3 reconstroi_e_classifica.py <sujeito.pt> <parte_software> <pasta_saidas_hw> <saida.txt>
"""
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


def encontra(pasta, prefixo):
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(prefixo)


def classifica(modelo, x_np):
    x_tensor = torch.from_numpy(x_np).float().unsqueeze(0)
    with torch.no_grad():
        logits = modelo(x_tensor)
        probs = torch.softmax(logits, dim=1)[0]
    prob_controle, prob_tea = probs[0].item(), probs[1].item()
    predicao = "TEA" if prob_tea > prob_controle else "controle"
    return predicao, prob_controle, prob_tea


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("parte_software")
    ap.add_argument("pasta_saidas_hw")
    ap.add_argument("saida_txt")
    args = ap.parse_args()

    tensor, label = torch.load(args.sujeito_pt, weights_only=False)
    x_bruto = np.nan_to_num(tensor.numpy(), nan=0.0, posinf=0.0, neginf=0.0)
    indices = np.load(encontra(args.parte_software, "indices_selecionados"))
    norm_mean = np.load(encontra(args.parte_software, "norm_mean"))
    norm_std = np.load(encontra(args.parte_software, "norm_std"))
    x_sem_filtro = (x_bruto[indices] - norm_mean) / norm_std
    n = len(x_sem_filtro)

    ESCALA_H, ESCALA_X = 2**30, 2**24
    x_com_filtro = np.zeros(n)
    for i in range(n):
        caminho = os.path.join(args.pasta_saidas_hw, f"pos_{i:03d}.txt")
        with open(caminho) as f:
            bruto = int(f.read().strip())
        x_com_filtro[i] = bruto / (ESCALA_H * ESCALA_X)

    codigo_classe = extrai_classe(
        os.path.join(args.parte_software, "loopTreino.py"), "FCN_Apresentacao1D")
    namespace = {"nn": nn}
    exec(codigo_classe, namespace)
    FCN_Apresentacao1D = namespace["FCN_Apresentacao1D"]

    modelo = FCN_Apresentacao1D()
    state_dict = torch.load(os.path.join(args.parte_software, "modeloTeste"),
                             map_location="cpu", weights_only=False)
    modelo.load_state_dict(state_dict)
    modelo.eval()

    pred_sem, pc_sem, pt_sem = classifica(modelo, x_sem_filtro)
    pred_com, pc_com, pt_com = classifica(modelo, x_com_filtro)
    rotulo_real = "TEA" if label == 1 else "controle"

    with open(args.saida_txt, "w") as f:
        f.write("# AVISO: filtro aplicado sobre a ordem de relevancia estatistica do\n")
        f.write("# SelectKBest, nao sobre serie temporal real (sem imagem fMRI bruta\n")
        f.write("# disponivel). Integracao mecanica hardware->software, nao validacao\n")
        f.write("# cientifica do ganho do filtro.\n")
        f.write(f"rotulo_real={rotulo_real}\n")
        f.write(f"predicao_sem_filtro={pred_sem}\n")
        f.write(f"prob_tea_sem_filtro={pt_sem:.6f}\n")
        f.write(f"acertou_sem_filtro={pred_sem == rotulo_real}\n")
        f.write(f"predicao_com_filtro={pred_com}\n")
        f.write(f"prob_tea_com_filtro={pt_com:.6f}\n")
        f.write(f"acertou_com_filtro={pred_com == rotulo_real}\n")
        f.write(f"predicao_mudou={pred_sem != pred_com}\n")

    print(f"sem filtro: {pred_sem} (p_tea={pt_sem:.3f})  |  com filtro: {pred_com} (p_tea={pt_com:.3f})  |  real: {rotulo_real}")


if __name__ == "__main__":
    main()
