# DIAAS-Integrado

Projeto integrado (hardware + software) do DIAAS. O objetivo é comparar a
detecção de TEA do **software puro** contra **hardware + software**, em que o
filtro temporal FIR roda no acelerador.

## Como obter as imagens

Disponíveis gratuitamente na plataforma ABIDE:
http://preprocessed-connectomes-project.org/abide/

Ou pelo script, que baixa direto do S3:

```bash
python3 scripts/baixa_imagens.py --limite <quantidade> --balanceado
```

## Como rodar

Após baixar as imagens, utilize os comandos:

```bash
make all     # hardware + software, e compara com o software puro
make clean   # remove o que foi gerado
```

Os dois lados da comparação saem do **mesmo** `make all`, sobre os **mesmos**
sujeitos: o `integra_hardware_software.py` roda o ramo com filtro (FIR no
acelerador) e o ramo de referência, que é a parte software **sozinha**.

`make all` roda a simulação do acelerador para cada ROI de cada sujeito, o que
leva cerca de 5 segundos por sujeito. Os sujeitos são independentes, então vale 
paralelizar esse processo:

```bash
make all -j8
```

## Onde ver os resultados

`resultados/` tem um `.txt` por sujeito. Cada um tem nove campos do resultado:

```
sujeito=Pitt_0050003
rotulo_real=TEA
predicao_sem_filtro=controle
prob_tea_sem_filtro=0.465089
acertou_sem_filtro=False
predicao_com_filtro=controle
prob_tea_com_filtro=0.480026
acertou_com_filtro=False
predicao_mudou=False
```