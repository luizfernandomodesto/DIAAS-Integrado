IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL_DIR        = parte_hardware/rtl
SIM_DIR        = parte_hardware/sim
SCRIPTS_DIR    = scripts
PARTE_SOFTWARE = parte_software
IMAGENS        = imagens
RESULT_DIR     = resultados

PESOS         = parte_hardware/weights/pesos_modelo.hex
STREAMING_DIR = parte_hardware/streaming_pt
SIM_BIN       = $(SIM_DIR)/streaming.vvp
SUJEITO_PT   ?=

STREAMING_SRCS = $(RTL_DIR)/receptor_uart.sv $(RTL_DIR)/empacotador_bytes.sv \
                 $(RTL_DIR)/memoria_circular.sv $(RTL_DIR)/memoria_pesos.sv \
                 $(RTL_DIR)/mac_dsp_streaming.sv $(RTL_DIR)/controlador_fsm_streaming.sv \
                 $(RTL_DIR)/transmissor_uart.sv $(RTL_DIR)/acelerador_streaming_top.sv

.PHONY: all software clean

all: $(SIM_BIN) $(PESOS)
	@mkdir -p $(RESULT_DIR)/hardware_software $(STREAMING_DIR)
	@grep -v '^//' $(PESOS) | head -127 > $(STREAMING_DIR)/pesos_streaming.hex
	@cp $(STREAMING_DIR)/pesos_streaming.hex pesos_modelo.hex
	@if [ -n "$(SUJEITO_PT)" ]; then lista="$(SUJEITO_PT)"; else lista="$(IMAGENS)/*.pt"; fi ; \
	for imagem in $$lista ; do \
		nome=$$(basename $$imagem .pt) ; \
		echo ">> [$$nome] Preparando amostras..." ; \
		$(PYTHON) $(SCRIPTS_DIR)/prepara_amostras_streaming.py $$imagem $(PARTE_SOFTWARE) $(STREAMING_DIR) ; \
		echo ">> [$$nome] Rodando no hardware..." ; \
		$(VVP) $(SIM_BIN) +AMOSTRAS=$(STREAMING_DIR)/$${nome}_amostras.hex +SAIDA=$(STREAMING_DIR)/$${nome}_resultado.txt ; \
		echo ">> [$$nome] Reconstruindo e classificando..." ; \
		$(PYTHON) $(SCRIPTS_DIR)/reconstroi_e_classifica.py $$imagem $(PARTE_SOFTWARE) $(STREAMING_DIR)/$${nome}_resultado.txt $(RESULT_DIR)/hardware_software/$$nome.txt ; \
	done

$(PESOS): $(PARTE_SOFTWARE)/preProcessamento.py $(SCRIPTS_DIR)/projeta_filtro_fir.py
	@$(PYTHON) $(SCRIPTS_DIR)/projeta_filtro_fir.py $(PARTE_SOFTWARE)/preProcessamento.py parte_hardware

$(SIM_BIN): $(STREAMING_SRCS) $(SIM_DIR)/tb_acelerador_streaming.sv
	$(IVERILOG) -g2012 -o $(SIM_BIN) $(STREAMING_SRCS) $(SIM_DIR)/tb_acelerador_streaming.sv

software:
	@mkdir -p $(RESULT_DIR)/software
	@for imagem in $(IMAGENS)/*.pt ; do \
		nome=$$(basename $$imagem .pt) ; \
		$(PYTHON) $(SCRIPTS_DIR)/roda_software.py $$imagem $(PARTE_SOFTWARE) $(RESULT_DIR)/software/$$nome.txt ; \
	done

clean:
	rm -f $(SIM_BIN) pesos_modelo.hex
	rm -rf $(RESULT_DIR) parte_hardware/weights $(STREAMING_DIR)
