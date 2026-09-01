# =============================================================================
# Makefile de verificacao hardware x software - acelerador DIAAS
#
# Estrutura do repositorio:
#   parte_software/   codigo e pesos reais do Thiago (intocados)
#   imagens/          sujeitos reais (.pt) - usados pelo lado SOFTWARE
#   scripts/          projeto do filtro, geracao de sinal, execucao do
#                     modelo real, calculo de precisao
#   parte_hardware/   RTL, testbench, dados gerados p/ simulacao
#   resultados/       saida de "make all" - hardware/ e software/, separados
#
# Os dois lados fazem coisas DIFERENTES, de proposito:
#   - HARDWARE: implementa o filtro temporal FIR (a etapa que a
#     Proposta_Hardware.pdf pede), com coeficientes projetados a partir das
#     frequencias de corte REAIS do pre-processamento do Thiago
#     (extraidas de parte_software/preProcessamento.py). Roda sobre sinal
#     sintetico (nao ha serie temporal bruta disponivel - ver scripts/
#     gera_sinal_teste.py).
#   - SOFTWARE: roda o sistema de classificacao REAL do Thiago
#     (FCN_Apresentacao1D, pesos treinados de verdade) sobre sujeitos
#     reais do ABIDE, em imagens/.
# NAO HA COMPARACAO AUTOMATICA entre os dois em "make all" - cada lado
# grava so o proprio resultado, com a propria precisao/metrica.
#
# O alvo "integracao" (separado, nao entra em "make all", ~10-15 min) faz
# uma terceira coisa: filtra as 512 posicoes do vetor real de um sujeito
# (.pt) no hardware, uma a uma, e alimenta o resultado no classificador
# real - comparando a predicao com e sem o filtro. AVISO: isso aplica o
# filtro sobre a ordem de relevancia estatistica do SelectKBest, nao sobre
# uma serie temporal real (nao ha imagem fMRI bruta disponivel) - e uma
# integracao mecanica do pipeline pedida explicitamente, nao uma validacao
# cientifica do ganho do filtro. Ver scripts/prepara_filtragem_pt.py.
#
# Uso:
#   make all         # projeta o filtro, gera sinais, compila, roda os dois lados
#   make imagens        # so mostra quais sujeitos serao processados (lado software)
#   make compile          # so compila o RTL + testbench de lote no Icarus
#   make hardware            # so roda o HARDWARE (filtro FIR, Icarus) 
#   make software              # so roda o SISTEMA REAL do Thiago (classificador)
#   make integracao              # filtra um sujeito real ponta a ponta (~10-15min)
#   make clean                     # remove binario compilado e resultados
#   make ajuda                       # mostra esta lista de novo
# =============================================================================

IVERILOG    ?= iverilog
VVP         ?= vvp
PYTHON      ?= python3

HW_ROOT           = parte_hardware
RTL_DIR           = $(HW_ROOT)/rtl
SIM_DIR           = $(HW_ROOT)/sim
SINAIS_DIR        = $(HW_ROOT)/sinais_teste
PESOS             = $(HW_ROOT)/weights/pesos_modelo.hex

SCRIPTS_DIR       = scripts
PARTE_SOFTWARE    = parte_software
PREPROCESSAMENTO  = $(PARTE_SOFTWARE)/preProcessamento.py
IMAGENS           = imagens

RESULT_DIR        = resultados
HW_RESULT_DIR     = $(RESULT_DIR)/hardware
SW_RESULT_DIR     = $(RESULT_DIR)/software
SIM_BIN           = $(SIM_DIR)/batch.vvp

RTL_SRCS = $(RTL_DIR)/acelerador_top.sv \
           $(RTL_DIR)/controlador_fsm.sv \
           $(RTL_DIR)/mac_dsp.sv \
           $(RTL_DIR)/memoria_bram.sv \
           $(RTL_DIR)/memoria_pesos.sv \
           $(RTL_DIR)/receptor_uart.sv \
           $(RTL_DIR)/transmissor_uart.sv \
           $(RTL_DIR)/empacotador_bytes.sv

.PHONY: all imagens filtro sinais compile hardware software integracao clean ajuda

all: filtro sinais compile hardware software
	@echo ""
	@echo ">> Feito. Resultados em $(HW_RESULT_DIR)/ e $(SW_RESULT_DIR)/ - compare manualmente."

ajuda:
	@echo "Alvos: imagens, filtro, sinais, compile, hardware, software, integracao, all, clean"
	@echo "  'integracao' e lento (~10-15 min, 512 chamadas ao simulador) - nao"
	@echo "  entra em 'make all'. Use SUJEITO_PT=imagens/X.pt para escolher o sujeito."

imagens:
	@echo ">> Sujeitos (lado software) em $(IMAGENS)/:"
	@ls -1 $(IMAGENS)/*.pt 2>/dev/null || echo "   (nenhum ainda - coloque arquivos .pt do cacheTeste em $(IMAGENS)/)"

# ----------------------------------------------------------------------------
# Projeta o filtro FIR a partir das frequencias de corte REAIS de
# preProcessamento.py. So refaz se esse arquivo mudar.
# ----------------------------------------------------------------------------
filtro: $(PESOS)

$(PESOS): $(PREPROCESSAMENTO) $(SCRIPTS_DIR)/projeta_filtro_fir.py
	@echo ">> Projetando filtro FIR a partir de $(PREPROCESSAMENTO) ..."
	@$(PYTHON) $(SCRIPTS_DIR)/projeta_filtro_fir.py $(PREPROCESSAMENTO) $(HW_ROOT)

# ----------------------------------------------------------------------------
# Gera o sinal sintetico de teste e as janelas de entrada do filtro.
# ----------------------------------------------------------------------------
sinais: $(PESOS)
	@echo ">> Gerando sinal de teste e janelas em $(SINAIS_DIR)/ ..."
	@$(PYTHON) $(SCRIPTS_DIR)/gera_sinal_teste.py $(PESOS) $(SINAIS_DIR)

# rtl/memoria_pesos.sv carrega os pesos com $readmemh("pesos_modelo.hex", ...)
# - caminho relativo fixo no proprio codigo. O Makefile garante uma copia
# local na raiz do repo (onde o vvp e chamado) antes de simular.
PESOS_LOCAL = pesos_modelo.hex

$(PESOS_LOCAL): $(PESOS)
	cp $(PESOS) $(PESOS_LOCAL)

# ----------------------------------------------------------------------------
# Compila o RTL + o testbench de lote (batch) no Icarus Verilog.
# ----------------------------------------------------------------------------
compile: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(SIM_DIR)/tb_acelerador_batch.sv
	@echo ">> Compilando com $(IVERILOG) ..."
	$(IVERILOG) -g2012 -o $(SIM_BIN) $(RTL_SRCS) $(SIM_DIR)/tb_acelerador_batch.sv

# ----------------------------------------------------------------------------
# HARDWARE: roda o filtro FIR sobre cada janela de sinal. So grava o
# proprio resultado (valor bruto + precisao contra a referencia exata da
# mesma operacao) - nenhuma comparacao com o software acontece aqui.
# ----------------------------------------------------------------------------
hardware: compile sinais $(PESOS_LOCAL)
	@mkdir -p $(HW_RESULT_DIR)
	@echo ">> Rodando HARDWARE (filtro FIR, Icarus Verilog) para cada janela ..."
	@for imagem in $(SINAIS_DIR)/*.hex ; do \
		nome=$$(basename $$imagem .hex) ; \
		echo "   - $$nome" ; \
		$(VVP) $(SIM_BIN) +IMAGEM=$$imagem +SAIDA=$(HW_RESULT_DIR)/$$nome.txt > $(HW_RESULT_DIR)/$$nome.log 2>&1 ; \
		if [ $$? -ne 0 ] || [ ! -f $(HW_RESULT_DIR)/$$nome.txt ]; then \
			echo "     ERRO ao simular $$nome - veja $(HW_RESULT_DIR)/$$nome.log" ; \
			exit 1 ; \
		fi ; \
		$(PYTHON) $(SCRIPTS_DIR)/precisao_filtro.py $(PESOS) $$imagem $(HW_RESULT_DIR)/$$nome.txt ; \
	done

# ----------------------------------------------------------------------------
# SOFTWARE: roda o sistema de classificacao REAL do Thiago sobre cada
# sujeito real. So grava o proprio resultado.
# ----------------------------------------------------------------------------
software:
	@mkdir -p $(SW_RESULT_DIR)
	@echo ">> Rodando SISTEMA REAL DO THIAGO (classificador) para cada sujeito ..."
	@for imagem in $(IMAGENS)/*.pt ; do \
		[ -e "$$imagem" ] || { echo "   nenhum sujeito .pt em $(IMAGENS)/ - veja 'make ajuda'"; exit 1; } ; \
		nome=$$(basename $$imagem .pt) ; \
		$(PYTHON) $(SCRIPTS_DIR)/roda_software.py $$imagem $(PARTE_SOFTWARE) $(SW_RESULT_DIR)/$$nome.txt ; \
	done

clean:
	rm -f $(SIM_BIN) $(PESOS_LOCAL)
	rm -rf $(RESULT_DIR) $(SINAIS_DIR) $(HW_ROOT)/weights $(HW_ROOT)/filtragem_pt

# ----------------------------------------------------------------------------
# INTEGRACAO hardware->software sobre um sujeito real (.pt): filtra as 512
# posicoes do vetor real (SelectKBest+normalizado) uma a uma no hardware, e
# alimenta o vetor filtrado no classificador real - comparando com o
# baseline sem filtro. LENTO (512 chamadas ao simulador, ~10-15 min por
# sujeito) - por isso NAO entra em "make all", e um alvo a parte.
#
# AVISO: o filtro aqui atua sobre a ordem de relevancia estatistica do
# SelectKBest, nao sobre uma serie temporal real (nao ha imagem fMRI bruta
# disponivel nesta sessao) - e uma integracao mecanica do pipeline, nao uma
# validacao cientifica do ganho do filtro. Ver scripts/prepara_filtragem_pt.py.
# ----------------------------------------------------------------------------
FILTRAGEM_DIR = $(HW_ROOT)/filtragem_pt
SUJEITO_PT   ?= $(firstword $(wildcard $(IMAGENS)/*.pt))

integracao: compile $(PESOS_LOCAL)
	@if [ -z "$(SUJEITO_PT)" ]; then echo "Nenhum .pt em $(IMAGENS)/"; exit 1; fi
	@nome=$$(basename $(SUJEITO_PT) .pt) ; \
	echo ">> Preparando janelas de $$nome (512 posicoes)..." ; \
	mkdir -p $(FILTRAGEM_DIR)/entradas $(FILTRAGEM_DIR)/saidas $(RESULT_DIR)/hardware_software ; \
	$(PYTHON) $(SCRIPTS_DIR)/prepara_filtragem_pt.py $(SUJEITO_PT) $(PARTE_SOFTWARE) $(PESOS) $(FILTRAGEM_DIR)/entradas ; \
	echo ">> Rodando as 512 posicoes no hardware (pode levar ~10-15 min)..." ; \
	for janela in $(FILTRAGEM_DIR)/entradas/*.hex ; do \
		n=$$(basename $$janela .hex) ; \
		$(VVP) $(SIM_BIN) +IMAGEM=$$janela +SAIDA=$(FILTRAGEM_DIR)/saidas/$$n.txt > /dev/null 2>&1 ; \
	done ; \
	echo ">> Reconstruindo o vetor filtrado e classificando..." ; \
	$(PYTHON) $(SCRIPTS_DIR)/reconstroi_e_classifica.py $(SUJEITO_PT) $(PARTE_SOFTWARE) $(FILTRAGEM_DIR)/saidas $(RESULT_DIR)/hardware_software/$$nome.txt
