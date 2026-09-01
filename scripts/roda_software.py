#!/usr/bin/env python3
"""
Roda o SISTEMA EM SOFTWARE de verdade: carrega a FCN_Apresentacao1D (a
classe definida em ProjetoTea-main/loopTreino.py - copiada aqui so leitura,
o arquivo original do Thiago nunca e tocado) com os pesos reais treinados
(ProjetoTea-main/pesos/modeloTeste), aplica o mesmo pre-processamento real
do preProcessamento.py (SelectKBest + normalizacao, usando os arquivos que
o Thiago exportou), e roda o forward() de verdade sobre um sujeito real do
cacheTeste do ABIDE.

Isso e o "sistema em software" que o professor pediu no Makefile - nao uma
reimplementacao da conta do hardware, o modelo de classificacao real.

Uso:
    python3 roda_software.py <sujeito.pt> <pasta_pesos_thiago> <saida.txt>
"""
import argparse
import ast
import os

import numpy as np
import torch
import torch.nn as nn


def extrai_classe_do_codigo_original(caminho_arquivo, nome_classe):
    """Extrai o codigo-fonte EXATO de uma classe de um arquivo .py do Thiago
    (codigo_thiago/loopTreino.py, copia byte a byte do original - nunca
    modificada), sem executar o resto do arquivo (que dispara um loop de
    treino inteiro e quebra sem os DataLoaders em memoria).

    Usa o modulo ast para achar os limites exatos da classe no arquivo real,
    em vez de copiar/colar o codigo a mao - assim fica impossivel usar uma
    versao desatualizada por engano (foi exatamente isso que aconteceu numa
    versao anterior deste script: a classe tinha sido copiada de um e-mail
    com uma versao antiga, faltando um stride=2 que so estava no arquivo
    .py real - resultado silenciosamente errado, corrigido depois).
    """
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
_codigo_classe = extrai_classe_do_codigo_original(
    CAMINHO_LOOPTREINO_ORIGINAL, "FCN_Apresentacao1D"
)
_namespace = {"nn": nn}
exec(_codigo_classe, _namespace)
FCN_Apresentacao1D = _namespace["FCN_Apresentacao1D"]


def encontra_arquivo(pasta, prefixo):
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(f"Nao encontrei {prefixo}*.npy em {pasta}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("sujeito_pt")
    ap.add_argument("pasta_pesos_thiago")
    ap.add_argument("saida_txt")
    args = ap.parse_args()

    tensor, label = torch.load(args.sujeito_pt, weights_only=False)
    x_bruto = tensor.numpy()
    x_bruto = np.nan_to_num(x_bruto, nan=0.0, posinf=0.0, neginf=0.0)

    indices = np.load(encontra_arquivo(args.pasta_pesos_thiago, "indices_selecionados"))
    norm_mean = np.load(encontra_arquivo(args.pasta_pesos_thiago, "norm_mean"))
    norm_std = np.load(encontra_arquivo(args.pasta_pesos_thiago, "norm_std"))
    x_final = (x_bruto[indices] - norm_mean) / norm_std

    modelo = FCN_Apresentacao1D()
    caminho_pth = os.path.join(args.pasta_pesos_thiago, "modeloTeste")
    state_dict = torch.load(caminho_pth, map_location="cpu", weights_only=False)
    modelo.load_state_dict(state_dict)
    modelo.eval()

    x_tensor = torch.from_numpy(x_final).float().unsqueeze(0)
    with torch.no_grad():
        logits = modelo(x_tensor)
        probs = torch.softmax(logits, dim=1)[0]

    prob_controle, prob_tea = probs[0].item(), probs[1].item()
    predicao = "TEA" if prob_tea > prob_controle else "controle"
    rotulo_real = "TEA" if label == 1 else "controle"

    with open(args.saida_txt, "w") as f:
        f.write(f"predicao={predicao}\n")
        f.write(f"prob_controle={prob_controle:.6f}\n")
        f.write(f"prob_tea={prob_tea:.6f}\n")
        f.write(f"rotulo_real={rotulo_real}\n")
        f.write(f"acertou={predicao == rotulo_real}\n")

    print(f"{os.path.basename(args.sujeito_pt)}: predicao={predicao} "
          f"(p_tea={prob_tea:.3f}) rotulo_real={rotulo_real}")


if __name__ == "__main__":
    main()
