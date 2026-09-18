# Makefile do DIAAS-Integrado
#
#   make all     -> roda tudo e grava resultados/<sujeito>.txt
#   make clean   -> remove o que foi gerado

# Usa o Python do .venv/ mesmo sem ativar
VENV_PY := $(wildcard .venv/bin/python3)
PYTHON  ?= $(if $(VENV_PY),$(VENV_PY),python3)
IVERILOG  ?= iverilog
VERILATOR ?= verilator

# Usa Verilator se tiver; senao Icarus, 36x mais lento e mesmo resultado
USA_VERILATOR := $(shell command -v $(VERILATOR) >/dev/null 2>&1 && echo sim)

RTL := parte_hardware/rtl
SIM := parte_hardware/sim
SW  := parte_software

ifeq ($(USA_VERILATOR),sim)
SIM_BIN := $(SIM)/obj_dir/streaming
else
SIM_BIN := $(SIM)/streaming.vvp
endif

# De onde vem o diagnostico de cada sujeito
FENOTIPO := Phenotypic_V1_0b_preprocessed1.csv

# Tira o sufixo _func_preproc: o nome tem que casar com o do CSV
NII_ARQS := $(wildcard imagens/*.nii.gz) $(wildcard imagens/*.nii)
NIIS     := $(sort $(patsubst %_func_preproc,%,\
                     $(basename $(basename $(notdir $(NII_ARQS))))))
RES      := $(addprefix resultados/,$(addsuffix .txt,$(NIIS)))

# Acha o arquivo do sujeito
arquivo_de = $(firstword $(wildcard imagens/$(1).nii.gz imagens/$(1)_func_preproc.nii.gz \
                                    imagens/$(1).nii imagens/$(1)_func_preproc.nii))

.PHONY: all clean
# Sem isto o make apaga os _ts.npy e re-extrai tudo
.SECONDARY:
.PRECIOUS: series/%_ts.npy series/%_meta.json

# ----------------------------------------------------------- hardware + software
all: $(RES)
ifeq ($(strip $(NIIS)),)
	@echo "Nao ha .nii.gz em imagens/, e o filtro precisa da imagem fMRI:"
	@echo "ele e um passa-faixa temporal, entao precisa do eixo do tempo."
	@echo ""
	@echo "Coloque em imagens/ SO imagens do ABIDE, do derivativo"
	@echo "nofilt_noglobal (nao filt_noglobal, que ja vem filtrado)."
	@echo "Serve .nii.gz ou .nii, com ou sem o sufixo _func_preproc:"
	@echo "  imagens/KKI_0050772.nii.gz"
	@echo "  imagens/KKI_0050772_func_preproc.nii.gz"
	@echo ""
	@echo "Para baixar de varios sites (um lote de um site so nao representa"
	@echo "a variacao de aquisicao do ABIDE):"
	@echo "  python3 scripts/baixa_imagens.py --limite 6 --balanceado"
	@echo "(--balanceado e obrigatorio na pratica: roda os sites e alterna a classe)"
	@echo ""
	@echo "E na raiz do repositorio, o CSV fenotipico (de onde vem o"
	@echo "diagnostico e o SITE_ID; o .nii.gz nao carrega desfecho clinico):"
	@echo "  $(FENOTIPO)"
	@echo ""
	@echo "Depois rode 'make all' de novo."
	@exit 1
else
	@echo ""
	@echo "Pronto: $(words $(NIIS)) arquivo(s) em resultados/, um por sujeito."
	@echo "Se algum sujeito saiu com AVISO acima (imagem ja filtrada), o"
	@echo "numero dele nao mede o filtro - a saida do make e o unico lugar"
	@echo "onde esse aviso aparece, entao vale rodar com: make all -j8 2>&1 | tee log.txt"
endif

# Baixa o atlas uma vez, senao com -j8 os processos se atropelam
ATLAS := series/.atlas_pronto

$(ATLAS):
	@mkdir -p $(dir $@)
	@echo "Baixando o atlas Schaefer-100 (uma vez, antes das extracoes)..."
	@$(PYTHON) -c "from nilearn import datasets; \
	  datasets.fetch_atlas_schaefer_2018(n_rois=100, yeo_networks=7, resolution_mm=2)"
	@touch $@

# Extrai as series, sem o passa-faixa (que e do hardware).
# Uma regra por forma do nome do arquivo.
# O | so garante a ordem: nao forca reextrair series que ja existem.
series/%_ts.npy: imagens/%.nii.gz scripts/extrai_series_temporais.py | $(ATLAS)
	@mkdir -p series
	@$(PYTHON) scripts/extrai_series_temporais.py $< series

series/%_ts.npy: imagens/%_func_preproc.nii.gz scripts/extrai_series_temporais.py | $(ATLAS)
	@mkdir -p series
	@$(PYTHON) scripts/extrai_series_temporais.py $< series

series/%_ts.npy: imagens/%.nii scripts/extrai_series_temporais.py | $(ATLAS)
	@mkdir -p series
	@$(PYTHON) scripts/extrai_series_temporais.py $< series

series/%_ts.npy: imagens/%_func_preproc.nii scripts/extrai_series_temporais.py | $(ATLAS)
	@mkdir -p series
	@$(PYTHON) scripts/extrai_series_temporais.py $< series

# Refaz o redes_roi.json se ele se perder
PRIMEIRO := $(firstword $(NIIS))

series/redes_roi.json: series/$(PRIMEIRO)_ts.npy
	@test -f $@ || $(PYTHON) scripts/extrai_series_temporais.py \
		$(call arquivo_de,$(PRIMEIRO)) series

# A ROM nao e dependencia: o script gera uma por TR
resultados/%.txt: series/%_ts.npy series/redes_roi.json \
                  $(SIM_BIN) scripts/integra_hardware_software.py
	@mkdir -p $(dir $@)
	@$(PYTHON) scripts/integra_hardware_software.py $< series/redes_roi.json $(SW) $@ \
		--sim $(SIM_BIN) --fenotipo $(FENOTIPO) \
		--preprocessamento $(SW)/preProcessamento.py

# --------------------------------------------------------------------- hardware
# INJECAO_DIRETA=1 pula a UART na simulacao
FONTES_RTL := $(wildcard $(RTL)/*.sv) $(SIM)/tb_acelerador_streaming.sv

$(SIM)/obj_dir/streaming: $(FONTES_RTL)
	$(VERILATOR) --binary --timing -Wno-fatal -j 0 \
		--top-module tb_acelerador_streaming -GINJECAO_DIRETA=1 \
		--Mdir $(SIM)/obj_dir -o streaming $(FONTES_RTL)

$(SIM)/streaming.vvp: $(FONTES_RTL)
	@mkdir -p $(dir $@)
	$(IVERILOG) -g2012 -Ptb_acelerador_streaming.INJECAO_DIRETA=1 -o $@ $(FONTES_RTL)

clean:
	rm -rf resultados $(SIM)/streaming.vvp $(SIM)/obj_dir \
		parte_hardware/weights scripts/__pycache__
