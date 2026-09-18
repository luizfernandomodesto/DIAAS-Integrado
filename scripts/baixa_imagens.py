#!/usr/bin/env python3
"""Baixa as imagens fMRI do ABIDE, do S3, em paralelo.

    python3 scripts/baixa_imagens.py --limite 20 --balanceado
"""
import argparse
import collections
import csv
import os
import shutil
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# nofilt_noglobal: o filt ja vem filtrado e o hardware nao teria o que fazer
BASE_S3 = (
    "https://s3.amazonaws.com/fcp-indi/data/Projects/ABIDE_Initiative"
    "/Outputs/cpac/nofilt_noglobal/func_preproc"
)


def ja_processados(pasta_resultados):
    """Nomes dos sujeitos que ja tem .txt na pasta de resultados."""
    if not pasta_resultados or not os.path.isdir(pasta_resultados):
        return set()
    return {
        os.path.basename(n)[:-4]
        for n in os.listdir(pasta_resultados)
        if n.endswith(".txt")
    }


def sujeitos_do_csv(caminho_csv, limite=None, balanceado=False, pular=()):
    """Le os FILE_ID do CSV fenotipico, ignorando as entradas sem imagem."""
    if not balanceado:
        with open(caminho_csv, newline="", encoding="utf-8-sig") as f:
            ids = [
                (l.get("FILE_ID") or "").strip()
                for l in csv.DictReader(f)
                if (l.get("FILE_ID") or "").strip() not in ("", "no_filename", "nan")
            ]
        ids = [i for i in ids if i not in pular]
        return ids[:limite] if limite else ids

    # por_site[SITE_ID] = ([tea...], [controle...])
    por_site = {}
    with open(caminho_csv, newline="", encoding="utf-8-sig") as f:
        for linha in csv.DictReader(f):
            fid = (linha.get("FILE_ID") or "").strip()
            if not fid or fid in ("no_filename", "nan"):
                continue
            site = (linha.get("SITE_ID") or "?").strip()
            tea, ctrl = por_site.setdefault(site, ([], []))
            (tea if (linha.get("DX_GROUP") or "").strip() == "1" else ctrl).append(fid)

    # Um TEA e um controle de cada site por volta, senao o --limite pega um site so
    ids, sites = [], sorted(por_site)
    while sites:
        for site in list(sites):
            tea, ctrl = por_site[site]
            if tea:
                ids.append(tea.pop(0))
            if ctrl:
                ids.append(ctrl.pop(0))
            if not tea and not ctrl:
                sites.remove(site)
    # Exclui antes de cortar, para --limite 300 dar 300 sujeitos novos
    ids = [i for i in ids if i not in pular]
    return ids[:limite] if limite else ids


# O que cada codigo de saida do curl significa
MOTIVO_CURL = {
    6:  "nao resolveu o DNS (sem rede?)",
    7:  "nao conectou ao S3",
    18: "transferencia incompleta (conexao caiu no meio)",
    22: "o S3 respondeu erro HTTP",
    23: "erro ao ESCREVER no disco (disco cheio?)",
    28: "tempo esgotado / transferencia travada",
    35: "erro de TLS",
    52: "o servidor nao respondeu nada",
    55: "falha ao enviar dados",
    56: "falha ao receber dados (conexao cortada)",
}


# Os curl em andamento, para o Ctrl+C conseguir mata-los
_EM_VOO = set()
_TRAVA = threading.Lock()
_ABORTAR = threading.Event()


def tamanhos_reais(ids, paralelos=16):
    """Tamanho de cada imagem, por HEAD no S3. Devolve (sujeito->bytes, ausentes)."""
    def um(suj):
        """Um HEAD: devolve (sujeito, bytes) ou (sujeito, None)."""
        try:
            r = subprocess.run(
                ["curl", "-sI", "--max-time", "20",
                 f"{BASE_S3}/{suj}_func_preproc.nii.gz"],
                capture_output=True, text=True,
            )
            for linha in r.stdout.splitlines():
                if linha.lower().startswith("content-length"):
                    return suj, int(linha.split(":")[1])
        except Exception:
            pass
        return suj, None
    try:
        with ThreadPoolExecutor(max_workers=paralelos) as ex:
            res = list(ex.map(um, ids))
    except Exception:
        return {}, []
    tam = {s: t for s, t in res if t}
    ausentes = [s for s, t in res if not t]
    # Nenhum respondeu: e falha de rede, nao imagem faltando
    if not tam:
        return {}, []
    return tam, ausentes


def _monitor(pasta, parar, intervalo=15):
    """Imprime o avanco a cada `intervalo` segundos, para mostrar se travou."""
    def no_disco():
        """Soma o tamanho dos arquivos da pasta."""
        total = 0
        try:
            for n in os.listdir(pasta):
                if n.endswith((".nii.gz", ".parcial")):
                    try:
                        total += os.path.getsize(os.path.join(pasta, n))
                    except OSError:
                        pass
        except OSError:
            pass
        return total

    t0 = time.time()
    anterior = no_disco()
    parado = 0
    while not parar.wait(intervalo):
        atual = no_disco()
        delta = atual - anterior
        taxa = delta / intervalo / 1048576
        minutos = (time.time() - t0) / 60
        if delta <= 0:
            parado += 1
            aviso = ("   <- sem avanco; se persistir, o curl aborta sozinho"
                     " apos 120 s parado" if parado >= 2 else "")
            print(f"    ... {minutos:4.1f} min | {atual / 1073741824:5.2f} GB"
                  f" no disco |  0.0 MB/s{aviso}", flush=True)
        else:
            parado = 0
            print(f"    ... {minutos:4.1f} min | {atual / 1073741824:5.2f} GB"
                  f" no disco | {taxa:4.1f} MB/s", flush=True)
        anterior = atual


def _encerra_tudo():
    """Mata os curl em voo. Chamada quando o usuario interrompe."""
    _ABORTAR.set()
    with _TRAVA:
        for proc in list(_EM_VOO):
            try:
                proc.terminate()
            except Exception:
                pass


def baixa(sujeito, pasta):
    """Baixa a imagem de um sujeito. Devolve (sujeito, status, bytes)."""
    destino = os.path.join(pasta, f"{sujeito}.nii.gz")
    if os.path.exists(destino) and os.path.getsize(destino) > 0:
        return (sujeito, "ja tinha", os.path.getsize(destino))

    url = f"{BASE_S3}/{sujeito}_func_preproc.nii.gz"
    parcial = destino + ".parcial"
    if _ABORTAR.is_set():
        return (sujeito, "cancelado", 0)
    # Baixa para .parcial e renomeia no fim, para nao sobrar arquivo incompleto
    # Popen, nao run: o objeto vai para _EM_VOO e o Ctrl+C consegue mata-lo
    proc = subprocess.Popen(
        ["curl", "-sSf", "--retry", "3", "--retry-delay", "2",
         "--continue-at", "-", "--speed-time", "120", "--speed-limit", "1000",
         "-w", "%{http_code}", "-o", parcial, url],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    with _TRAVA:
        _EM_VOO.add(proc)
    try:
        saida, erro_txt = proc.communicate()
    finally:
        with _TRAVA:
            _EM_VOO.discard(proc)
    if _ABORTAR.is_set():
        return (sujeito, "cancelado", 0)
    r = subprocess.CompletedProcess(proc.args, proc.returncode, saida, erro_txt)
    if r.returncode != 0 or not os.path.exists(parcial):
        http = (r.stdout or "").strip()
        erro = (r.stderr or "").strip().splitlines()
        motivo = MOTIVO_CURL.get(r.returncode, f"curl saiu com codigo {r.returncode}")
        if http == "404":
            motivo = "nao existe neste derivativo (HTTP 404)"
        elif http and http != "200":
            motivo = f"o S3 respondeu HTTP {http}"
        detalhe = f" - {erro[-1][:70]}" if erro else ""
        # O .parcial fica no disco, para a proxima execucao retomar
        return (sujeito, f"FALHOU: {motivo}{detalhe}", 0)
    tam = os.path.getsize(parcial)
    os.replace(parcial, destino)
    return (sujeito, "ok", tam)


def main():
    """Confere o espaco em disco e baixa o lote."""
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pasta", default="imagens")
    ap.add_argument("--fenotipo", default="Phenotypic_V1_0b_preprocessed1.csv")
    ap.add_argument("--sujeitos", nargs="+", default=None,
                    help="FILE_IDs especificos; sem isto, usa todos do CSV")
    ap.add_argument("--limite", type=int, default=None,
                    help="quantos sujeitos baixar (comece com 6 para testar)."
                    " Sem isto, baixa todos os 1035 do CSV")
    ap.add_argument("--balanceado", action="store_true",
                    help="escolhe rodando site e alternando classe. USE SEMPRE"
                    " junto com --limite: sem isto os N primeiros saem de um"
                    " site so e de uma classe so, e ai nao da para calcular"
                    " especificidade e AUC nem representar a variacao do ABIDE")
    ap.add_argument("--pular", default="resultados", metavar="PASTA",
                    help="pula quem ja tem resultados/<sujeito>.txt nesta"
                    " pasta, para rodar em lotes sem repetir sujeito. A"
                    " exclusao acontece ANTES do --limite, entao --limite 300"
                    " traz 300 NOVOS. Passe --pular '' para desligar")
    ap.add_argument("--paralelos", type=int, default=4,
                    help="downloads simultaneos. 4 rendeu 3x sobre sequencial;"
                    " acima de ~8 costuma nao ajudar")
    args = ap.parse_args()

    if args.sujeitos:
        ids = args.sujeitos
    else:
        if not os.path.exists(args.fenotipo):
            raise SystemExit(
                f"ERRO: {args.fenotipo} nao encontrado. Baixe de:\n"
                "  https://s3.amazonaws.com/fcp-indi/data/Projects/"
                "ABIDE_Initiative/Phenotypic_V1_0b_preprocessed1.csv\n"
                "Ou passe --sujeitos com os FILE_IDs."
            )
        pular = ja_processados(args.pular)
        if pular:
            print(f"pulando {len(pular)} sujeitos que ja tem .txt em"
                  f" {args.pular}/ (lote anterior)")
        ids = sujeitos_do_csv(args.fenotipo, args.limite, args.balanceado,
                              pular)
        if not ids:
            raise SystemExit(
                f"Nada novo para baixar: todos os sujeitos do CSV ja tem"
                f" resultado em {args.pular}/.\n"
                "O CSV do ABIDE tem 1035 sujeitos com imagem."
            )

    os.makedirs(args.pasta, exist_ok=True)

    # Avisa do espaco antes: com o disco cheio o curl aborta no meio
    ja = sum(1 for s in ids
             if os.path.exists(os.path.join(args.pasta, f"{s}.nii.gz")))
    livre = shutil.disk_usage(args.pasta).free
    print(f"{len(ids)} sujeitos ({ja} ja no disco), {args.paralelos} em paralelo"
          f" -> {args.pasta}/")

    print("consultando o tamanho real das imagens no S3...", flush=True)
    tamanhos, ausentes = tamanhos_reais(ids)
    if tamanhos:
        falta_baixar = [s for s in ids
                        if not os.path.exists(os.path.join(args.pasta,
                                                           f"{s}.nii.gz"))]
        preciso = sum(tamanhos.get(s, 105 * 1024**2) for s in falta_baixar)
        medio = preciso / max(1, len(falta_baixar))
        print(f"espaco: {livre / 1024**3:.1f} GB livres,"
              f" {preciso / 1024**3:.1f} GB necessarios"
              f" (medido, media {medio / 1048576:.0f} MB por imagem)")
        if ausentes:
            print(f"  {len(ausentes)} sujeitos nao existem neste derivativo e"
                  f" serao pulados: {', '.join(ausentes[:4])}"
                  + (" ..." if len(ausentes) > 4 else ""))
    else:
        preciso = (len(ids) - ja) * 105 * 1024**2
        print(f"espaco: {livre / 1024**3:.1f} GB livres,"
              f" ~{preciso / 1024**3:.1f} GB necessarios"
              f" (estimado por media - os HEAD ao S3 falharam)")
    if preciso > livre:
        print(f"\n!! AVISO: pode nao caber. Faltariam"
              f" ~{(preciso - livre) / 1024**3:.1f} GB.")
        print("   Baixe em lotes (--limite menor) ou libere espaco;"
              " com o disco cheio o curl aborta")
        print("   e a falha aparece como 'erro ao ESCREVER no disco'.\n")

    # Dois downloads na mesma pasta corrompem os .parcial um do outro
    trava = os.path.join(args.pasta, ".baixando.pid")
    if os.path.exists(trava):
        try:
            with open(trava) as f:
                pid_antigo = int(f.read().strip())
            os.kill(pid_antigo, 0)
            vivo = True
        except (ValueError, ProcessLookupError, FileNotFoundError):
            vivo = False
        except PermissionError:
            vivo = True
        if vivo:
            raise SystemExit(
                f"ERRO: ja existe um download rodando nesta pasta"
                f" (PID {pid_antigo}).\n"
                "Dois downloads na mesma pasta corrompem os arquivos .parcial.\n"
                f"Espere ele terminar, ou pare com:  kill {pid_antigo}\n"
                f"Se tem certeza que nao ha nada rodando:  rm {trava}"
            )
        print(f"  (trava orfa de um run anterior, removendo)")
        os.remove(trava)
    with open(trava, "w") as f:
        f.write(str(os.getpid()))

    total = falhas = pulados = cancelados = 0
    motivos = collections.Counter()

    print(f"\nbaixando (cada imagem tem 66-138 MB; a primeira linha sai"
          f" quando o primeiro arquivo terminar)...", flush=True)
    print("  para acompanhar em outro terminal:  du -sh imagens/", flush=True)

    # as_completed, nao map: o map segura os prontos atras de um sujeito lento
    interrompido = False
    parar_monitor = threading.Event()
    monitor = threading.Thread(target=_monitor, args=(args.pasta, parar_monitor),
                               daemon=True)
    monitor.start()
    try:
        ex = ThreadPoolExecutor(max_workers=args.paralelos)
        futuros = {ex.submit(baixa, s, args.pasta): s for s in ids}
        try:
            for i, fut in enumerate(as_completed(futuros), 1):
                suj, status, tam = fut.result()
                if status == "ok":
                    total += tam
                    print(f"  [{i}/{len(ids)}] {suj}:"
                          f" {tam / 1048576:.0f} MB"
                          f"  (total {total / 1073741824:.1f} GB)", flush=True)
                elif status == "ja tinha":
                    pulados += 1
                elif status == "cancelado":
                    cancelados += 1
                else:
                    falhas += 1
                    motivos[status.split(" - ")[0]] += 1
                    print(f"  [{i}/{len(ids)}] {suj}: {status}",
                          file=sys.stderr, flush=True)
        except KeyboardInterrupt:
            # Mata os curl antes do shutdown, senao ele fica esperando por eles
            interrompido = True
            print("\n\ninterrompendo os downloads em voo...", flush=True)
            _encerra_tudo()
            for f in futuros:
                f.cancel()
        ex.shutdown(wait=True, cancel_futures=True)
    finally:
        parar_monitor.set()
        try:
            os.remove(trava)
        except OSError:
            pass

    if interrompido:
        print("Interrompido. Os .parcial ficam no disco e a proxima execucao"
              " retoma de onde parou.")
        print("Nenhum curl continuou rodando - pode rodar o comando de novo"
              " com seguranca.")
        raise SystemExit(130)

    print(f"\nbaixados: {total / 1073741824:.2f} GB"
          f" | ja tinha: {pulados} | falhas: {falhas}")
    if falhas:
        print("\nFalhas por motivo (o motivo e o que o curl reportou, nao um chute):")
        for motivo, n in motivos.most_common():
            print(f"  {n:>4}x  {motivo}")
        print("\nSo 'nao existe neste derivativo (HTTP 404)' e definitivo. Os")
        print("outros motivos sao recuperaveis: rode o mesmo comando de novo e")
        print("ele retoma os downloads parciais de onde pararam.")
    print("\nAgora rode: make all -j8")
    print("\nPara continuar em lotes (disco pequeno), depois que o make"
          " terminar:")
    print("  1. confira que resultados/ tem um .txt por sujeito deste lote")
    print("  2. apague as imagens:  rm -f imagens/*.nii.gz imagens/*.nii")
    print("  3. rode este mesmo comando de novo - ele pula quem ja tem .txt")
    print("NAO apague resultados/ (200 bytes por sujeito): e ele que diz o que"
          " ja rodou.")


if __name__ == "__main__":
    main()
