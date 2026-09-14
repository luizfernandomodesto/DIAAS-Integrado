#!/usr/bin/env python3
# Remonta o vetor filtrado a partir do resultado do hardware e classifica
# com e sem o filtro, pra comparar os dois.
import argparse
import ast
import os

import numpy as np
import torch
import torch.nn as nn


def extrai_classe(caminho_arquivo, nome_classe):
    # Pega o código de uma classe direto do arquivo original, sem copiar à mão
    with open(caminho_arquivo, encoding="utf-8") as f:
        codigo_fonte = f.read()
    arvore = ast.parse(codigo_fonte)
    for node in arvore.body:
        if isinstance(node, ast.ClassDef) and node.name == nome_classe:
            return ast.get_source_segment(codigo_fonte, node)
    raise ValueError(f"Classe {nome_classe} nao encontrada em {caminho_arquivo}")


def encontra(pasta, prefixo):
    # Acha o .npy que começa com esse nome (tipo "norm_mean") na pasta
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(prefixo)


def classifica(modelo, x_np):
    # Roda o forward() e devolve a predição junto com as duas probabilidades
    x_tensor = torch.from_numpy(x_np).float().unsqueeze(0)
    with torch.no_grad():
        logits = modelo(x_tensor)
        probs = torch.softmax(logits, dim=1)[0]
    prob_controle, prob_tea = (probs[0].item(), probs[1].item())
    predicao = "TEA" if prob_tea > prob_controle else "controle"
    return (predicao, prob_controle, prob_tea)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("parte_software")
    ap.add_argument("resultado_hw_txt")
    ap.add_argument("saida_txt")
    args = ap.parse_args()

    # Vetor sem filtro: a mesma seleção e normalização do preProcessamento.py
    tensor, label = torch.load(args.sujeito_pt, weights_only=False)
    x_bruto = np.nan_to_num(tensor.numpy(), nan=0.0, posinf=0.0, neginf=0.0)
    indices = np.load(encontra(args.parte_software, "indices_selecionados"))
    norm_mean = np.load(encontra(args.parte_software, "norm_mean"))
    norm_std = np.load(encontra(args.parte_software, "norm_std"))
    x_sem_filtro = (x_bruto[indices] - norm_mean) / norm_std
    n = len(x_sem_filtro)

    # Vetor com filtro: lê o resultado do hardware e reescala pra número real
    ESCALA_H, ESCALA_X = (2**30, 2**24)
    with open(args.resultado_hw_txt) as f:
        brutos = [int(l.strip()) for l in f if l.strip()]
    if len(brutos) != n:
        raise SystemExit(
            f"ERRO: esperava {n} resultados do hardware, achei {len(brutos)}"
        )
    x_com_filtro = np.array(brutos) / (ESCALA_H * ESCALA_X)

    # Carrega o classificador real e classifica os dois vetores
    codigo_classe = extrai_classe(
        os.path.join(args.parte_software, "loopTreino.py"), "FCN_Apresentacao1D"
    )
    namespace = {"nn": nn}
    exec(codigo_classe, namespace)
    FCN_Apresentacao1D = namespace["FCN_Apresentacao1D"]
    modelo = FCN_Apresentacao1D()
    state_dict = torch.load(
        os.path.join(args.parte_software, "modeloTeste"),
        map_location="cpu",
        weights_only=False,
    )
    modelo.load_state_dict(state_dict)
    modelo.eval()
    pred_sem, pc_sem, pt_sem = classifica(modelo, x_sem_filtro)
    pred_com, pc_com, pt_com = classifica(modelo, x_com_filtro)
    rotulo_real = "TEA" if label == 1 else "controle"

    with open(args.saida_txt, "w") as f:
        # O filtro roda sobre a ordem do SelectKBest (relevância estatística),
        # não sobre uma série temporal real - o .pt já não tem esse eixo.
        # Isso mostra a integração hardware->software funcionando, não prova
        # ganho científico do filtro.
        f.write("# AVISO: filtro roda sobre a ordem do SelectKBest (relevancia\n")
        f.write("# estatistica), nao sobre serie temporal real - o .pt ja nao\n")
        f.write("# tem esse eixo. Mostra a integracao hardware->software\n")
        f.write("# funcionando, nao prova ganho cientifico do filtro.\n")
        f.write(f"rotulo_real={rotulo_real}\n")
        f.write(f"predicao_sem_filtro={pred_sem}\n")
        f.write(f"prob_tea_sem_filtro={pt_sem:.6f}\n")
        f.write(f"acertou_sem_filtro={pred_sem == rotulo_real}\n")
        f.write(f"predicao_com_filtro={pred_com}\n")
        f.write(f"prob_tea_com_filtro={pt_com:.6f}\n")
        f.write(f"acertou_com_filtro={pred_com == rotulo_real}\n")
        f.write(f"predicao_mudou={pred_sem != pred_com}\n")
    print(
        f"sem filtro: {pred_sem} (p_tea={pt_sem:.3f})  |  com filtro: {pred_com} (p_tea={pt_com:.3f})  |  real: {rotulo_real}"
    )


if __name__ == "__main__":
    main()
