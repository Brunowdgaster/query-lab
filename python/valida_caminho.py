#!/usr/bin/env python3
"""valida_caminho.py — o caminho é VÁLIDO, em vez de idêntico ao esperado.

    .venv/bin/python cypher/roda.py caminho --json \
        | python3 python/valida_caminho.py --saltos 4

## Por que a comparação literal estava errada

A primeira versão deste projeto gravava a resposta da pergunta do caminho em
`dados/esperado/caminho.json` e comparava as outras implementações contra ela,
byte a byte -- a mesma estratégia que funciona para a pergunta do alcance.

Medindo o Kuzu, as duas cláusulas de menor caminho deram respostas
**diferentes e as duas corretas**:

    SHORTEST       Ana -> Bruno -> Diego -> Fabio -> Gabi    4 saltos
    ALL SHORTEST   Ana -> Carla -> Elisa -> Fabio -> Gabi    4 saltos

Olhando o grafo, é obvio em retrospecto: Ana alcança Fabio por dois lados
(via Bruno/Diego e via Carla/Elisa), com o mesmo comprimento. **O menor
caminho não é único**, e qual deles um motor devolve é escolha de
implementação -- ordem de armazenamento, ordem de expansão, otimizador.

Então comparar o caminho literalmente testaria a ORDEM INTERNA de cada motor,
e reprovaria respostas corretas. O que é bem definido, e igual em todos, é:

  1. o número de saltos;
  2. que os extremos são Ana e Gabi;
  3. que cada par consecutivo é realmente uma amizade;
  4. que nenhum nó se repete (um passeio que revisita não é caminho).

Este script verifica as quatro. É mais trabalho que um `diff`, e é a
verificação certa: ela aceita toda resposta correta e recusa toda errada.

A pergunta do alcance **continua** com comparação literal, e deve: ali a
resposta é um conjunto com distâncias mínimas, que é único.
"""

import argparse
import csv
import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DADOS = os.path.join(RAIZ, "dados")


def arestas():
    """O conjunto de amizades, nos dois sentidos, direto do CSV."""
    with open(os.path.join(DADOS, "pessoas.csv"), encoding="utf-8") as fh:
        nome_de = {int(r["id"]): r["nome"] for r in csv.DictReader(fh)}

    pares = set()
    with open(os.path.join(DADOS, "amizades.csv"), encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            a, b = nome_de[int(r["a"])], nome_de[int(r["b"])]
            pares.add((a, b))
            pares.add((b, a))
    return pares


def valida(res, saltos_esperados, origem, destino):
    """Devolve a lista de problemas. Vazia significa caminho válido."""
    problemas = []

    if not isinstance(res, dict):
        return [f"esperava um objeto JSON, veio {type(res).__name__}"]

    if not res.get("existe"):
        problemas.append("a resposta diz que não existe caminho")
        return problemas

    caminho = res.get("caminho") or []
    saltos = res.get("saltos")

    # 1. O numero de saltos, que e o que a pergunta de fato determina.
    if saltos != saltos_esperados:
        problemas.append(
            f"saltos={saltos}, esperado {saltos_esperados}")

    # O comprimento da lista e o numero de saltos mais um. Conferir os dois
    # pega a confusao classica entre "numero de nos" e "numero de arestas",
    # que e o off-by-one desta consulta -- e que passaria se so o campo
    # `saltos` fosse olhado, porque ele pode estar certo com a lista errada.
    if len(caminho) != saltos_esperados + 1:
        problemas.append(
            f"o caminho tem {len(caminho)} nó(s), esperado "
            f"{saltos_esperados + 1} para {saltos_esperados} saltos")

    if not caminho:
        return problemas

    # 2. Os extremos.
    if caminho[0] != origem or caminho[-1] != destino:
        problemas.append(
            f"extremos {caminho[0]}..{caminho[-1]}, "
            f"esperado {origem}..{destino}")

    # 3. Cada par consecutivo e uma amizade de verdade.
    #
    # Este e o teste que pega resposta INVENTADA: um motor pode devolver uma
    # lista do tamanho certo, com os extremos certos, e um salto que nao
    # existe no grafo.
    pares = arestas()
    for i in range(len(caminho) - 1):
        if (caminho[i], caminho[i + 1]) not in pares:
            problemas.append(
                f"{caminho[i]} e {caminho[i + 1]} não são amigos "
                f"(passo {i + 1})")

    # 4. Nenhum no repetido.
    if len(set(caminho)) != len(caminho):
        repetidos = sorted({n for n in caminho if caminho.count(n) > 1})
        problemas.append(
            f"nó(s) repetido(s): {', '.join(repetidos)} "
            f"-- um passeio que revisita não é caminho")

    return problemas


def main():
    ap = argparse.ArgumentParser(
        description="valida um caminho em vez de compará-lo literalmente")
    ap.add_argument("--saltos", type=int, required=True,
                    help="número de saltos que a resposta deve ter")
    ap.add_argument("--origem", default="Ana")
    ap.add_argument("--destino", default="Gabi")
    ap.add_argument("--rotulo", default="caminho",
                    help="nome da implementação, para a mensagem")
    args = ap.parse_args()

    try:
        res = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"  FALHA {args.rotulo}: JSON inválido na entrada: {e}")
        return 1

    problemas = valida(res, args.saltos, args.origem, args.destino)

    if not problemas:
        rota = " -> ".join(res["caminho"])
        print(f"  ok    {args.rotulo}: {args.saltos} saltos, caminho válido "
              f"({rota})")
        return 0

    print(f"  FALHA {args.rotulo}:")
    for p in problemas:
        print(f"        {p}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
