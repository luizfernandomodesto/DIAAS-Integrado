#!/usr/bin/env python3
"""Extrai as series temporais de ROI

Use imagens de nofilt_noglobal do ABIDE
"""
import argparse
import json
import os

import numpy as np


def main():
    """Roda o masker e grava as series, o TR e as redes de cada ROI."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("imagem_nii", help="arquivo *_func_preproc.nii.gz do ABIDE")
    ap.add_argument("pasta_saida")
    ap.add_argument(
        "--tr",
        type=float,
        default=None,
        help="TR em segundos. Padrao: le do cabecalho NIfTI, como o"
        " preProcessamento.py faz (indice 3 do get_zooms)",
    )
    args = ap.parse_args()

    import nibabel as nib
    from nilearn import datasets
    from nilearn.maskers import NiftiLabelsMasker

    # Mesmo atlas do preProcessamento.py
    atlas = datasets.fetch_atlas_schaefer_2018(
        n_rois=100, yeo_networks=7, resolution_mm=2
    )
    atlas_labels = []
    for label in atlas.labels:
        nome = label.decode() if isinstance(label, bytes) else str(label)
        if nome != "Background":
            atlas_labels.append(nome)

    # TR do cabecalho, convertendo de milissegundos se preciso
    if args.tr is None:
        img = nib.load(args.imagem_nii)
        tr = float(img.header.get_zooms()[3])
        if tr > 20:
            tr = tr / 1000.0
    else:
        tr = args.tr

    # Sem low_pass/high_pass: o passa-faixa e do hardware
    masker = NiftiLabelsMasker(
        labels_img=atlas.maps,
        standardize="zscore_sample",
        detrend=True,
        t_r=tr,
    )
    ts = masker.fit_transform(args.imagem_nii)

    os.makedirs(args.pasta_saida, exist_ok=True)
    nome = os.path.basename(args.imagem_nii)
    for sufixo in ("_func_preproc.nii.gz", "_func_preproc.nii", ".nii.gz", ".nii"):
        nome = nome.replace(sufixo, "")
    caminho_ts = os.path.join(args.pasta_saida, f"{nome}_ts.npy")
    np.save(caminho_ts, ts.astype(np.float64))

    # O TR e por sujeito (varia por site) e o filtro depende dele
    caminho_meta = os.path.join(args.pasta_saida, f"{nome}_meta.json")
    with open(caminho_meta, "w") as f:
        json.dump(
            {"tr_s": tr, "n_instantes": int(ts.shape[0]), "n_rois": int(ts.shape[1])},
            f,
            indent=2,
        )

    # Rede funcional de cada ROI (campo [2] do nome Schaefer)
    redes = [
        (lb.decode() if isinstance(lb, bytes) else str(lb)).split("_")[2]
        for lb in atlas_labels
    ]
    # Todos os sujeitos gravam este arquivo; renomear e atomico, escrever nao
    caminho_redes = os.path.join(args.pasta_saida, "redes_roi.json")
    parcial = f"{caminho_redes}.{os.getpid()}"
    with open(parcial, "w") as f:
        json.dump({"redes": redes}, f, indent=2)
    os.replace(parcial, caminho_redes)

    print(f"Gerado: {caminho_ts}  {ts.shape} (instantes x ROIs), TR={tr}s")
    print(f"Gerado: {caminho_meta} (TR deste sujeito)")
    print(f"Gerado: {caminho_redes} ({len(set(redes))} redes, iguais para todos)")
    print("Passa-faixa NAO aplicado - fica para o hardware.")


if __name__ == "__main__":
    main()
