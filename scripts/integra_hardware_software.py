#!/usr/bin/env python3
"""Junta o acelerador de hardware e o classificador de software.
"""
import argparse
import ast
import csv
import json
import math
import os
import re
import subprocess
import tempfile

import numpy as np
import torch
import torch.nn as nn
from scipy import signal

ESCALA_X = 2**24
N_ROIS_ESPERADO = 100
NUMTAPS = 127  # numero de coeficientes do filtro

# Corte superior do filtro do hardware. Saiu de teste, nao de teoria.
LOW_PASS_HARDWARE = 0.090


def to_hex32(v):
    """Formata um inteiro como 8 digitos hex (complemento de dois, 32 bits)."""
    return format(int(v) & 4294967295, "08x")


# ==========================================================================
# LADO HARDWARE: projeto do filtro, que alimenta a ROM do acelerador
# ==========================================================================
def extrai_cortes(caminho_preprocessamento):
    """Le high_pass e low_pass do preProcessamento.py, em vez de copiar."""
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
    """Maior escala de ponto fixo que ainda cabe em int32."""
    max_abs = float(np.abs(pesos_float).max())
    if max_abs == 0:
        return 2**28
    bits_livres = 31 - 2
    expoente = bits_livres - math.ceil(math.log2(max_abs))
    return 2 ** max(1, expoente)


def gera_rom(pasta_pesos, corte_alto, corte_baixo, tr, numtaps=NUMTAPS):
    """Projeta o FIR de um TR e grava a ROM (.hex) e os metadados (.json).

    Ha uma ROM por TR: o filtro depende de fs=1/TR e a banda sairia errada.
    """
    fs = 1.0 / tr
    nyquist = fs / 2.0
    if not 0 < corte_alto < corte_baixo < nyquist:
        raise SystemExit(
            f"ERRO: cortes {corte_alto}-{corte_baixo}Hz invalidos para fs={fs}Hz"
            f" (Nyquist={nyquist}Hz), TR={tr}s."
        )
    taps = signal.firwin(
        numtaps, [corte_alto, corte_baixo], pass_zero=False, fs=fs, window="hamming"
    )
    escala = escolhe_escala(taps)
    h_int = np.round(taps * escala).astype(np.int64)
    if np.abs(h_int).max() >= 2**31:
        raise SystemExit(
            f"ERRO: estouro de int32 com escala=2^{escala.bit_length() - 1}"
        )
    os.makedirs(pasta_pesos, exist_ok=True)
    sufixo = f"tr{tr:g}".replace(".", "p")
    caminho_hex = os.path.join(pasta_pesos, f"pesos_{sufixo}.hex")
    expoente = escala.bit_length() - 1
    cabecalho = [
        f"// Filtro FIR temporal, {numtaps} taps (janela de Hamming).",
        f"// Cortes: high_pass={corte_alto} Hz, low_pass={corte_baixo} Hz.",
        f"// TR={tr}s (fs={fs}Hz).",
        f"// Ponto fixo: valor_inteiro = round(valor_real * 2^{expoente}).",
    ]
    with open(caminho_hex, "w") as f:
        f.write("\n".join(cabecalho + [to_hex32(v) for v in h_int]) + "\n")

    meta = {
        "numtaps": numtaps,
        "expoente_escala_h": expoente,
        "escala_h": int(escala),
        "high_pass_hz": corte_alto,
        "low_pass_hz": corte_baixo,
        "tr_s": tr,
        "fs_hz": fs,
        "janela": "hamming",
        "atraso_grupo_amostras": (numtaps - 1) // 2,
        "ganho_dc": float(taps.sum()),
    }
    caminho_json = os.path.join(pasta_pesos, f"pesos_{sufixo}.json")
    with open(caminho_json, "w") as f:
        json.dump(meta, f, indent=2)
    return caminho_hex, caminho_json, meta


def extrai_classe(caminho, nome):
    """Devolve o codigo-fonte de uma classe, lido por AST do arquivo."""
    with open(caminho, encoding="utf-8") as f:
        src = f.read()
    for node in ast.parse(src).body:
        if isinstance(node, ast.ClassDef) and node.name == nome:
            return ast.get_source_segment(src, node)
    raise ValueError(f"Classe {nome} nao encontrada em {caminho}")


def rotulo_do_fenotipo(caminho_csv, sujeito):
    """Le o diagnostico no CSV do ABIDE (DX_GROUP == 1 e TEA)."""
    with open(caminho_csv, newline="", encoding="utf-8-sig") as f:
        for linha in csv.DictReader(f):
            if (linha.get("FILE_ID") or "").strip() == sujeito:
                dx = (linha.get("DX_GROUP") or "").strip()
                return "TEA" if dx == "1" else "controle"
    return None


def encontra_npy(pasta, prefixo):
    """Acha o primeiro .npy da pasta que comeca com o prefixo."""
    for nome in os.listdir(pasta):
        if nome.startswith(prefixo) and nome.endswith(".npy"):
            return os.path.join(pasta, nome)
    raise FileNotFoundError(f"Nao encontrei {prefixo}*.npy em {pasta}")


# Imagem nao filtrada tem 30-50% da energia acima do corte; a filtrada, ~1%
FRACAO_MIN_FORA_DA_BANDA = 0.08


def fracao_acima_do_corte(ts, fs, corte_baixo):
    """Fracao da energia acima do corte superior."""
    espectro = np.abs(np.fft.rfft(ts, axis=0)) ** 2
    freqs = np.fft.rfftfreq(ts.shape[0], d=1.0 / fs)
    total = espectro[1:].sum()  # sem o DC
    if total <= 0:
        return 0.0
    return float(espectro[freqs > corte_baixo].sum() / total)


# ==========================================================================
# LADO HARDWARE: serializar, rodar o RTL, reconstruir e conferir
# ==========================================================================
def estende_impar(coluna, n_ini, n_fim):
    """Estende as pontas da serie. Tem de ser impar: a par suja a banda medida."""
    return np.pad(coluna, (n_ini, n_fim), mode="reflect", reflect_type="odd")


def serializa_para_o_acelerador(ts, numtaps, atraso):
    """Poe as ROIs num fluxo unico, com as pontas estendidas.

    Sem isso as primeiras saidas de cada ROI sairiam erradas.
    """
    pad_ini = numtaps - 1
    fluxo, deslocamento = [], pad_ini + atraso
    passo = pad_ini + ts.shape[0] + atraso
    for r in range(ts.shape[1]):
        col = estende_impar(ts[:, r], pad_ini, atraso)
        fluxo.extend(np.round(col * ESCALA_X).astype(np.int64).tolist())
    return fluxo, passo, deslocamento


def comando_simulador(sim_bin):
    """Icarus gera um .vvp que roda sob `vvp`; o Verilator gera um executavel."""
    return ["vvp", sim_bin] if sim_bin.endswith(".vvp") else [sim_bin]


def confere_derivativo(ts, meta):
    """Avisa se a imagem parece ja vir filtrada"""
    fracao = fracao_acima_do_corte(ts, meta["fs_hz"], meta["low_pass_hz"])
    if fracao < FRACAO_MIN_FORA_DA_BANDA:
        print(f"  !! AVISO: so {fracao:.1%} da energia esta acima de"
              f" {meta['low_pass_hz']} Hz (esperado 30-50%).")
        print("     Esta imagem parece JA vir filtrada - derivativo"
              " filt_noglobal em vez de nofilt_noglobal.")
        print("     Nesse caso o hardware nao tem o que filtrar, os dois ramos"
              " saem quase iguais")
        print("     e a comparacao nao mede nada. Baixe de"
              " cpac/nofilt_noglobal/func_preproc.")
    else:
        print(f"  energia acima de {meta['low_pass_hz']} Hz: {fracao:.1%}"
              " (ok, imagem nao filtrada)")


def filtra_no_acelerador(ts, sim_bin, pesos_hex, meta):
    """A etapa do hardware: passa as ROIs pelo acelerador e remonta a matriz."""
    n_t, n_rois = ts.shape
    numtaps, atraso = meta["numtaps"], meta["atraso_grupo_amostras"]
    fluxo, passo, deslocamento = serializa_para_o_acelerador(ts, numtaps, atraso)
    if max(abs(v) for v in fluxo) >= 2**31:
        raise SystemExit("ERRO: estouro de int32 nas amostras")

    with tempfile.TemporaryDirectory() as tmp:
        ent = os.path.join(tmp, "amostras.hex")
        sai = os.path.join(tmp, "saida.txt")
        with open(ent, "w") as f:
            f.write("\n".join(to_hex32(v) for v in fluxo) + "\n")
        r = subprocess.run(
            comando_simulador(sim_bin)
            + [f"+PESOS={pesos_hex}", f"+AMOSTRAS={ent}", f"+SAIDA={sai}",
               f"+LIMPA_CADA={passo}"],
            capture_output=True,
            text=True,
        )
        if not os.path.exists(sai):
            raise SystemExit(f"ERRO na simulacao:\n{r.stdout}\n{r.stderr}")
        with open(sai) as f:
            bruto = np.array([int(l) for l in f if l.strip()], dtype=np.float64)

    if len(bruto) != len(fluxo):
        raise SystemExit(f"ERRO: hw devolveu {len(bruto)}, esperava {len(fluxo)}")

    ts_hw = np.zeros_like(ts)
    for r in range(n_rois):
        ini = r * passo + deslocamento
        ts_hw[:, r] = bruto[ini : ini + n_t] / (meta["escala_h"] * ESCALA_X)
    return ts_hw


def filtra_no_software(ts, fs_hz, high_pass_hz, low_pass_hz):
    """O mesmo passa-faixa em software. Nao e usada: o ramo de referencia nao filtra."""
    sos = signal.butter(
        5, [high_pass_hz, low_pass_hz], btype="bandpass", fs=fs_hz, output="sos"
    )
    return signal.sosfiltfilt(sos, ts, axis=0)


def confere_fidelidade(ts, ts_hw, meta):
    """Refaz a conta em numpy e compara: diferenca acima de 1 LSB e erro do hardware."""
    numtaps, atraso = meta["numtaps"], meta["atraso_grupo_amostras"]
    taps = signal.firwin(
        numtaps,
        [meta["high_pass_hz"], meta["low_pass_hz"]],
        pass_zero=False,
        fs=meta["fs_hz"],
        window="hamming",
    )
    h_quant = np.round(taps * meta["escala_h"]) / meta["escala_h"]
    desl = numtaps - 1 + atraso
    n_t = ts.shape[0]
    ref_fir = np.apply_along_axis(
        lambda c: np.convolve(estende_impar(c, numtaps - 1, atraso),
                              h_quant)[desl : desl + n_t],
        0, ts,
    )
    erro = float(np.max(np.abs(ts_hw - ref_fir)))
    print(f"fidelidade hw vs FIR de referencia: erro_max={erro:.3e}"
          f" (1 LSB = {1 / ESCALA_X:.3e})")


# ==========================================================================
# LADO SOFTWARE: classificador do Thiago
# ==========================================================================
def carrega_modelo(pasta_parte_software):
    """Carrega a rede, os indices e a normalizacao de parte_software/."""
    ns = {"nn": nn}
    exec(
        extrai_classe(
            os.path.join(pasta_parte_software, "loopTreino.py"),
            "FCN_Apresentacao1D",
        ),
        ns,
    )
    modelo = ns["FCN_Apresentacao1D"]()
    modelo.load_state_dict(
        torch.load(
            os.path.join(pasta_parte_software, "modeloTeste"),
            map_location="cpu",
            weights_only=False,
        )
    )
    modelo.eval()
    return (
        modelo,
        np.load(encontra_npy(pasta_parte_software, "indices_selecionados")),
        np.load(encontra_npy(pasta_parte_software, "norm_mean")),
        np.load(encontra_npy(pasta_parte_software, "norm_std")),
    )


def correlacao_ledoit_wolf(ts):
    """Correlacao com encolhimento (Mesma do estimador do preProcessamento.py)"""
    from sklearn.covariance import LedoitWolf

    x = np.asarray(ts, dtype=np.float64)
    # standardize="zscore_sample" do nilearn: z-score por coluna, ddof=1
    desvio = x.std(axis=0, ddof=1)
    desvio[desvio == 0] = 1.0
    z = np.nan_to_num((x - x.mean(axis=0)) / desvio, nan=0.0,
                      posinf=0.0, neginf=0.0)
    cov = LedoitWolf(store_precision=False).fit(z).covariance_
    d = np.sqrt(np.diag(cov))
    d[d == 0] = 1.0
    return cov / np.outer(d, d)


def monta_conectividade(ts, redes):
    """Monta o vetor de 4971 features igual ao preProcessamento.py."""
    desvio = ts.std(axis=0, ddof=1)
    desvio[desvio == 0] = 1.0
    ts = np.nan_to_num((ts - ts.mean(axis=0)) / desvio, nan=0.0,
                       posinf=0.0, neginf=0.0)
    n_rois = ts.shape[1]

    # --- network-level FC: sinal medio de cada rede, na ordem de aparicao ---
    ordem_redes, indices_por_rede = [], {}
    for i, rede in enumerate(redes):
        if rede not in indices_por_rede:
            indices_por_rede[rede] = []
            ordem_redes.append(rede)
        indices_por_rede[rede].append(i)
    sinais_rede = np.array(
        [ts[:, indices_por_rede[rede]].mean(axis=1) for rede in ordem_redes]
    )
    net_corr = np.corrcoef(sinais_rede)
    triu_redes = np.triu_indices(len(ordem_redes), k=1)
    net_vec = np.arctanh(np.clip(net_corr[triu_redes], -0.99, 0.99))

    # --- ROI-level FC, reordenada por par de redes ---
    mat = correlacao_ledoit_wolf(ts)
    triu = np.triu_indices(n_rois, k=1)
    conn = mat[triu]
    rotulos_aresta = [
        tuple(sorted([redes[i], redes[j]])) for i, j in zip(triu[0], triu[1])
    ]
    ordem = sorted(range(len(rotulos_aresta)), key=lambda x: rotulos_aresta[x])
    conn = np.arctanh(np.clip(conn[ordem], -0.99, 0.99))

    return np.concatenate([conn, net_vec])


def classifica(modelo, x):
    """Roda o modelo e devolve (predicao, probabilidade de TEA)."""
    with torch.no_grad():
        probs = torch.softmax(modelo(torch.from_numpy(x).float().unsqueeze(0)), 1)[0]
    pc, pt = probs[0].item(), probs[1].item()
    return ("TEA" if pt > pc else "controle"), pt


def main():
    """Roda os dois ramos num sujeito e grava o .txt da comparacao."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("series_npy", help="*_ts.npy do extrai_series_temporais.py")
    ap.add_argument("redes_json", help="redes_roi.json do extrai_series_temporais.py")
    ap.add_argument("parte_software")
    ap.add_argument("saida_txt")
    ap.add_argument("--fenotipo", default="Phenotypic_V1_0b_preprocessed1.csv",
                    help="CSV do ABIDE: diagnostico (DX_GROUP) e SITE_ID")
    ap.add_argument("--sim", default="parte_hardware/sim/streaming.vvp",
                    help=".vvp (Icarus, roda sob vvp) ou executavel (Verilator);"
                         " o Makefile escolhe o disponivel")
    ap.add_argument("--preprocessamento",
                    default="parte_software/preProcessamento.py",
                    help="de onde vem as frequencias de corte do filtro")
    ap.add_argument("--pesos-dir", default="parte_hardware/weights")
    args = ap.parse_args()

    # O TR varia por site e o filtro depende dele: ha uma ROM por TR
    caminho_meta_suj = args.series_npy.replace("_ts.npy", "_meta.json")
    if not os.path.exists(caminho_meta_suj):
        raise SystemExit(
            f"ERRO: {caminho_meta_suj} nao existe. Refaca a extracao com"
            " scripts/extrai_series_temporais.py (ele grava o TR do sujeito)."
        )
    with open(caminho_meta_suj) as f:
        tr = float(json.load(f)["tr_s"])
    corte_alto, corte_baixo = extrai_cortes(args.preprocessamento)
    args.pesos, _, meta = gera_rom(
        args.pesos_dir, corte_alto, LOW_PASS_HARDWARE, tr
    )
    print(f"TR do sujeito: {tr}s (fs={meta['fs_hz']:.4f} Hz)")
    # So a banda do hardware e anunciada: o ramo de referencia nao filtra
    print(f"  banda: hardware {corte_alto}-{LOW_PASS_HARDWARE} Hz"
          f" | software puro: nenhuma (banda pretendida pelo"
          f" preProcessamento.py: {corte_alto}-{corte_baixo} Hz)")

    sujeito = os.path.basename(args.series_npy)
    for sufixo in ("_ts.npy", ".npy"):
        sujeito = sujeito.replace(sufixo, "")
    rotulo_real = (rotulo_do_fenotipo(args.fenotipo, sujeito)
                   if os.path.exists(args.fenotipo) else None)
    if rotulo_real is None:
        print(f"  aviso: sem rotulo para {sujeito} em {args.fenotipo};"
              " saida sem as linhas rotulo_real e acertou_*")

    ts = np.load(args.series_npy)
    if ts.ndim != 2:
        raise SystemExit("ERRO: series_npy deve ser 2D (instantes x ROIs)")
    n_t, n_rois = ts.shape
    with open(args.redes_json) as f:
        redes = json.load(f)["redes"]
    if len(redes) != n_rois:
        raise SystemExit(f"ERRO: {len(redes)} redes para {n_rois} ROIs")
    print(f"series: {n_t} instantes x {n_rois} ROIs")

    confere_derivativo(ts, meta)

    # --- Ramo hardware: o FIR roda no acelerador ---
    ts_hw = filtra_no_acelerador(ts, args.sim, args.pesos, meta)

    # --- Ramo de referencia: a parte software sozinha, sem filtro nenhum ---
    ts_sw = ts

    # --- O acelerador acertou? Contra a MESMA matematica em software ---
    confere_fidelidade(ts, ts_hw, meta)

    modelo, indices, mean, std = carrega_modelo(args.parte_software)

    # Daqui em diante os dois ramos seguem igual. Nada vale para so um deles.
    resultados = {}
    for ramo, serie in [("sem_filtro", ts_sw), ("com_filtro", ts_hw)]:
        vetor = np.nan_to_num(monta_conectividade(serie, redes), nan=0.0,
                              posinf=0.0, neginf=0.0)
        if len(vetor) != len(mean) and max(indices) >= len(vetor):
            raise SystemExit(
                f"ERRO: vetor de conectividade tem {len(vetor)} features, mas"
                f" indices_selecionados chega a {max(indices)}."
                f" Confira se o atlas tem {N_ROIS_ESPERADO} ROIs."
            )
        x = (vetor[indices] - mean) / std
        resultados[ramo] = classifica(modelo, x)

    pred_sw, pt_sw = resultados["sem_filtro"]
    pred_hw, pt_hw = resultados["com_filtro"]

    # O .txt do paciente tem so os nove campos do resultado
    saida = [f"sujeito={sujeito}"]
    if rotulo_real:
        saida.append(f"rotulo_real={rotulo_real}")
    saida += [f"predicao_sem_filtro={pred_sw}",
              f"prob_tea_sem_filtro={pt_sw:.6f}"]
    if rotulo_real:
        saida.append(f"acertou_sem_filtro={pred_sw == rotulo_real}")
    saida += [f"predicao_com_filtro={pred_hw}",
              f"prob_tea_com_filtro={pt_hw:.6f}"]
    if rotulo_real:
        saida.append(f"acertou_com_filtro={pred_hw == rotulo_real}")
    saida.append(f"predicao_mudou={pred_sw != pred_hw}")

    os.makedirs(os.path.dirname(args.saida_txt) or ".", exist_ok=True)
    with open(args.saida_txt, "w") as f:
        f.write("\n".join(saida) + "\n")
    print(
        f"software puro (sem filtro): {pred_sw} (p_tea={pt_sw:.3f})  |  "
        f"hardware + software (FIR): {pred_hw} (p_tea={pt_hw:.3f})"
    )
    print(f"Salvo em {args.saida_txt}")


if __name__ == "__main__":
    main()
