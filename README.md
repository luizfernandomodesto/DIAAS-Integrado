# DIAAS-Integrado

Este repositório é o projeto integrado (hardware + software) do DIAAS. O
objetivo principal é rodar `make all` e olhar as pastas de resultado pra
verificar se o filtro no hardware melhora a detecção do classificador,
comparando a predição com e sem o filtro.

## Imagens

A pasta `imagens/` já vem com 30 sujeitos reais do ABIDE, retirados
aleatoriamente do banco de dados completo — para ser possível testar o programa utilizando
`make all` direto, sem precisar baixar.

O banco de dados completo (todos os sujeitos processados) está disponível
aqui: https://drive.google.com/drive/folders/1fL3aENIbXSorvtPJF3YRZlWHNoguGWdL?usp=sharing

## Como rodar

```bash
make all         # filtro + hardware + classificador, com e sem filtro
                  # (~5 segundos por sujeito)
make software     # só o classificador, sem hardware
```

## O que cada `make` faz

| Alvo | O que faz |
|---|---|
| `all` | **O teste principal.** Filtra um sujeito real no hardware, classifica com e sem o filtro, e grava os dois resultados lado a lado |
| `software` | Roda o classificador real (feito pelo Thiago) sobre cada sujeito em `imagens/` |
| `clean` | Remove os arquivos gerados (binário compilado, resultados) |

## Onde ver os resultados

- `resultados/software/<sujeito>.txt` — predição do classificador puro (sem hardware)
- `resultados/hardware_software/<sujeito>.txt` — predição com e sem filtro, lado a lado, gerado por `make all`

É esse último arquivo que responde a pergunta principal do projeto: o
filtro no hardware ajudou ou não a acertar o diagnóstico daquele paciente.
