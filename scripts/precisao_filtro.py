#!/usr/bin/env python3
"""
Calcula a PRECISAO do filtro FIR no hardware: reescala o valor bruto do
acumulador e compara contra a referencia float64 exata (gravada no
cabeçalho do proprio arquivo de entrada por gera_sinal_teste.py).

Uso:
    python3 precisao_filtro.py <pesos.hex> <janela.hex> <resultado_hw.txt>
"""
import argparse
import re


def le_valor_cabecalho(caminho_hex, padrao):
    with open(caminho_hex) as f:
        for linha in f:
            if not linha.startswith("//"):
                break
            m = re.search(padrao, linha)
            if m:
                return m.group(1)
    raise ValueError(f"Nao achei '{padrao}' no cabecalho de {caminho_hex}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("pesos_hex")
    ap.add_argument("janela_hex")
    ap.add_argument("resultado_hw_txt")
    args = ap.parse_args()

    escala_h = 2 ** int(le_valor_cabecalho(args.pesos_hex, r"2\^(\d+)"))
    escala_x = 2 ** int(le_valor_cabecalho(args.janela_hex, r"2\^(\d+)"))
    referencia = float(le_valor_cabecalho(args.janela_hex, r"referencia_float64=([-\d.]+)"))

    with open(args.resultado_hw_txt) as f:
        valor_bruto = int(f.read().strip())
    valor_reescalado = valor_bruto / (escala_h * escala_x)

    erro_abs = abs(valor_reescalado - referencia)
    erro_rel = erro_abs / abs(referencia) if referencia != 0 else float("nan")

    with open(args.resultado_hw_txt, "w") as f:
        f.write(f"valor_bruto={valor_bruto}\n")
        f.write(f"escala_pesos=2^{escala_h.bit_length()-1}\n")
        f.write(f"escala_entrada=2^{escala_x.bit_length()-1}\n")
        f.write(f"valor_reescalado={valor_reescalado:.6f}\n")
        f.write(f"referencia_float64={referencia:.6f}\n")
        f.write(f"erro_absoluto={erro_abs:.3e}\n")
        f.write(f"erro_relativo={erro_rel:.3e}\n")

    print(f"   precisao: erro relativo = {erro_rel:.3e}")


if __name__ == "__main__":
    main()
