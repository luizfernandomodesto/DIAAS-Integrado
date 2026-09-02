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

filtro: $(PESOS)

$(PESOS): $(PREPROCESSAMENTO) $(SCRIPTS_DIR)/projeta_filtro_fir.py
	@echo ">> Projetando filtro FIR a partir de $(PREPROCESSAMENTO) ..."
	@$(PYTHON) $(SCRIPTS_DIR)/projeta_filtro_fir.py $(PREPROCESSAMENTO) $(HW_ROOT)

sinais: $(PESOS)
	@echo ">> Gerando sinal de teste e janelas em $(SINAIS_DIR)/ ..."
	@$(PYTHON) $(SCRIPTS_DIR)/gera_sinal_teste.py $(PESOS) $(SINAIS_DIR)

# rtl/memoria_pesos.sv carrega os pesos com $readmemh("pesos_modelo.hex", ...)
# - caminho relativo fixo no proprio codigo. O Makefile garante uma copia
# local na raiz do repo (onde o vvp e chamado) antes de simular.
PESOS_LOCAL = pesos_modelo.hex

$(PESOS_LOCAL): $(PESOS)
	cp $(PESOS) $(PESOS_LOCAL)

compile: $(SIM_BIN)

$(SIM_BIN): $(RTL_SRCS) $(SIM_DIR)/tb_acelerador_batch.sv
	@echo ">> Compilando com $(IVERILOG) ..."
	$(IVERILOG) -g2012 -o $(SIM_BIN) $(RTL_SRCS) $(SIM_DIR)/tb_acelerador_batch.sv

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

software:
	@mkdir -p $(SW_RESULT_DIR)
	@echo ">> Rodando o Software para cada sujeito ..."
	@for imagem in $(IMAGENS)/*.pt ; do \
		[ -e "$$imagem" ] || { echo "   nenhum sujeito .pt em $(IMAGENS)/ - veja 'make ajuda'"; exit 1; } ; \
		nome=$$(basename $$imagem .pt) ; \
		$(PYTHON) $(SCRIPTS_DIR)/roda_software.py $$imagem $(PARTE_SOFTWARE) $(SW_RESULT_DIR)/$$nome.txt ; \
	done

clean:
	rm -f $(SIM_BIN) $(PESOS_LOCAL)
	rm -rf $(RESULT_DIR) $(SINAIS_DIR) $(HW_ROOT)/weights $(HW_ROOT)/filtragem_pt

FILTRAGEM_DIR = $(HW_ROOT)/filtragem_pt
SUJEITO_PT   ?= $(firstword $(wildcard $(IMAGENS)/*.pt))

integracao: compile $(PESOS_LOCAL)
	@mkdir -p $(RESULT_DIR)/hardware_software
	@if [ -n "$(SUJEITO_PT)" ]; then lista="$(SUJEITO_PT)"; else lista="$(IMAGENS)/*.pt"; fi ; \
	for imagem in $$lista ; do \
		nome=$$(basename $$imagem .pt) ; \
		echo ">> [$$nome] Preparando janelas (512 posicoes)..." ; \
		mkdir -p $(FILTRAGEM_DIR)/entradas/$$nome $(FILTRAGEM_DIR)/saidas/$$nome ; \
		$(PYTHON) $(SCRIPTS_DIR)/prepara_filtragem_pt.py $$imagem $(PARTE_SOFTWARE) $(PESOS) $(FILTRAGEM_DIR)/entradas/$$nome ; \
		echo ">> [$$nome] Rodando as 512 posicoes no hardware..." ; \
		for janela in $(FILTRAGEM_DIR)/entradas/$$nome/*.hex ; do \
			n=$$(basename $$janela .hex) ; \
			$(VVP) $(SIM_BIN) +IMAGEM=$$janela +SAIDA=$(FILTRAGEM_DIR)/saidas/$$nome/$$n.txt > /dev/null 2>&1 ; \
		done ; \
		echo ">> [$$nome] Reconstruindo e classificando..." ; \
		$(PYTHON) $(SCRIPTS_DIR)/reconstroi_e_classifica.py $$imagem $(PARTE_SOFTWARE) $(FILTRAGEM_DIR)/saidas/$$nome $(RESULT_DIR)/hardware_software/$$nome.txt ; \
	done
