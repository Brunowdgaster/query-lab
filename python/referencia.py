#!/usr/bin/env python3
"""referencia.py — a resposta correta, calculada do jeito mais simples possível.

    python3 python/referencia.py alcance
    python3 python/referencia.py caminho
    python3 python/referencia.py --gravar

## Por que esta implementação existe primeiro

As outras sete implementações deste projeto respondem à mesma pergunta em SQL,
PL/pgSQL, PL/SQL, T-SQL, Cypher, SPARQL e GraphQL. Todas têm de dar **a mesma
resposta** — e para isso é preciso uma resposta de referência em que se possa
confiar.

Esta é ela, e a escolha de Python é deliberada: uma busca em largura explícita
é a coisa mais simples que existe para este problema. Não há otimizador, não há
planejador de consulta, não há índice. Se o BFS estiver errado, está errado de
um jeito que se vê lendo dez linhas.

O portfólio já usou essa estratégia duas vezes: o `.fbc` do p01 é montado pela
implementação em C e executado pelos sete portes; os 23 casos do p02 são
gerados pelo compilador em Haskell e conferidos pelos portes em OCaml e F#. A
referência é sempre a implementação mais simples, não a mais rápida.

## As duas perguntas, e por que elas

**Alcance:** *quem está a até 3 saltos de amizade de Ana?*

Ela separa **modelos de dados**, não dialetos:

| linguagem | como se expressa |
|---|---|
| SQL | CTE recursivo, com controle de ciclo à mão |
| Cypher | `-[:AMIGO*1..3]-`, uma expressão |
| SPARQL | *property path* `foaf:knows{1,3}` |
| GraphQL | **não se expressa** — ver `graphql/README` |
| Python | BFS de dez linhas |

E o limite de 3 corta no meio do grafo: Gabi está a 4 saltos e **tem de ficar
de fora**. Um limite que abrangesse o componente inteiro não testaria a
contagem de saltos.

**Caminho:** *qual o menor caminho de Ana até Gabi?*

Essa é a que o SQL faz pior: um CTE recursivo acha os caminhos, mas escolher o
menor exige carregar todos e ordenar, enquanto Cypher tem `shortestPath` e o
SPARQL... também não tem. A comparação fica honesta nas duas direções.
"""

import csv
import json
import os
import sys
from collections import deque

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DADOS = os.path.join(RAIZ, "dados")
ESPERADO = os.path.join(DADOS, "esperado")

ORIGEM = "Ana"
DESTINO = "Gabi"
LIMITE = 3


def carrega():
    """Lê os três CSV e devolve (pessoas por id, nome por id, adjacência)."""
    with open(os.path.join(DADOS, "pessoas.csv"), encoding="utf-8") as fh:
        pessoas = {int(r["id"]): r for r in csv.DictReader(fh)}

    nome_de = {i: p["nome"] for i, p in pessoas.items()}
    id_de = {p["nome"]: i for i, p in pessoas.items()}

    # A amizade é NÃO DIRIGIDA, e o arquivo guarda cada aresta UMA vez.
    #
    # Espelhar aqui, numa linha, é o que em SQL custa um `UNION ALL` dentro do
    # CTE recursivo e em Cypher custa escrever `-[:AMIGO]-` em vez de
    # `-[:AMIGO]->`. É a primeira diferença entre os modelos, e ela aparece
    # antes de qualquer consulta.
    adj = {i: set() for i in pessoas}
    with open(os.path.join(DADOS, "amizades.csv"), encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            a, b = int(r["a"]), int(r["b"])
            adj[a].add(b)
            adj[b].add(a)

    return pessoas, nome_de, id_de, adj


def alcance(adj, inicio, limite):
    """BFS com limite de profundidade. Devolve {id: saltos}.

    O `visitados` é o que impede ciclo. Em SQL isso não vem de graça: um CTE
    recursivo sobre grafo com ciclo roda para sempre, e a defesa usual é
    carregar o caminho inteiro num array e testar pertinência a cada passo --
    que é o que `sql/alcance.sql` faz, com o comentário explicando por quê.
    """
    saltos = {inicio: 0}
    fila = deque([inicio])

    while fila:
        atual = fila.popleft()
        if saltos[atual] >= limite:
            continue
        for viz in sorted(adj[atual]):
            if viz not in saltos:
                saltos[viz] = saltos[atual] + 1
                fila.append(viz)

    # A origem sai do resultado: a pergunta é "quem está a até 3 saltos DE
    # Ana", e Ana está a zero saltos de si mesma. Incluí-la seria uma resposta
    # defensável e diferente, então a decisão fica explícita aqui e na mesma
    # linha em cada uma das outras sete implementações.
    del saltos[inicio]
    return saltos


def menor_caminho(adj, inicio, fim):
    """BFS guardando o predecessor. Devolve a lista de ids, ou None."""
    if inicio == fim:
        return [inicio]

    anterior = {inicio: None}
    fila = deque([inicio])

    while fila:
        atual = fila.popleft()
        for viz in sorted(adj[atual]):
            if viz in anterior:
                continue
            anterior[viz] = atual
            if viz == fim:
                caminho = [fim]
                while anterior[caminho[-1]] is not None:
                    caminho.append(anterior[caminho[-1]])
                return list(reversed(caminho))
            fila.append(viz)

    return None


def resposta_alcance():
    _, nome_de, id_de, adj = carrega()
    res = alcance(adj, id_de[ORIGEM], LIMITE)

    # Ordenado por (saltos, nome): a comparação entre oito implementações
    # exige uma ordem TOTAL e determinística. Sem ela, duas respostas certas
    # pareceriam diferentes, e o verificador acusaria uma divergência que não
    # existe -- erro que já apareceu neste portfólio ao comparar JSON com
    # chaves em ordens diferentes.
    return [
        {"nome": nome_de[i], "saltos": s}
        for i, s in sorted(res.items(), key=lambda kv: (kv[1], nome_de[kv[0]]))
    ]


def resposta_caminho():
    _, nome_de, id_de, adj = carrega()
    cam = menor_caminho(adj, id_de[ORIGEM], id_de[DESTINO])

    if cam is None:
        return {"existe": False, "saltos": None, "caminho": []}

    return {
        "existe": True,
        "saltos": len(cam) - 1,
        "caminho": [nome_de[i] for i in cam],
    }


def imprime_alcance(res):
    print(f"Pessoas a até {LIMITE} saltos de amizade de {ORIGEM}:")
    print()
    print(f"{'nome':<10} {'saltos':>6}")
    print("-" * 18)
    for r in res:
        print(f"{r['nome']:<10} {r['saltos']:>6}")
    print("-" * 18)
    print(f"{len(res)} pessoa(s)")


def imprime_caminho(res):
    print(f"Menor caminho de amizade de {ORIGEM} até {DESTINO}:")
    print()
    if not res["existe"]:
        print("  não há caminho")
        return
    print(f"  {' -> '.join(res['caminho'])}")
    print(f"  {res['saltos']} saltos")


def main():
    args = sys.argv[1:]

    if "--gravar" in args:
        os.makedirs(ESPERADO, exist_ok=True)

        for nome, valor in (
            ("alcance.json", resposta_alcance()),
            ("caminho.json", resposta_caminho()),
        ):
            caminho = os.path.join(ESPERADO, nome)
            with open(caminho, "w", encoding="utf-8", newline="\n") as fh:
                json.dump(valor, fh, ensure_ascii=False, indent=2,
                          sort_keys=True)
                fh.write("\n")
            print(f"gravado: dados/esperado/{nome}")

        return 0

    if not args or args[0] not in ("alcance", "caminho"):
        print("uso: referencia.py {alcance|caminho} [--json]", file=sys.stderr)
        print("     referencia.py --gravar", file=sys.stderr)
        return 64

    pergunta = args[0]
    como_json = "--json" in args

    res = resposta_alcance() if pergunta == "alcance" else resposta_caminho()

    if como_json:
        print(json.dumps(res, ensure_ascii=False, indent=2, sort_keys=True))
    elif pergunta == "alcance":
        imprime_alcance(res)
    else:
        imprime_caminho(res)

    return 0


if __name__ == "__main__":
    sys.exit(main())
