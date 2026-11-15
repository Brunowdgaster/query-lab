#!/usr/bin/env python3
"""roda.py — carrega o domínio no Kuzu e roda as consultas Cypher.

    .venv/bin/python cypher/roda.py alcance
    .venv/bin/python cypher/roda.py caminho
    .venv/bin/python cypher/roda.py --json

## Por que Kuzu, e não Neo4j

Kuzu é **embarcado** (como o SQLite), licença MIT, e fala Cypher. Instala com
`pip install kuzu` e não exige servidor, JVM nem contêiner.

Neo4j Community também é livre, mas é um servidor em JVM: ~500 MB e um
processo para subir e derrubar no CI. Para comparar **modelos de dados**, o
servidor não acrescenta nada — e a regra declarada do portfólio é não gastar
recurso que não paga por si.

A ressalva honesta: Kuzu implementa um **subconjunto** do Cypher do Neo4j.
`shortestPath()` existe, `allShortestPaths()` também, mas as funções de
algoritmo de grafo (`gds.*`) são exclusivas do Neo4j e não são usadas aqui.
Nada neste projeto depende delas.

## O Python aqui é encanamento, não a linguagem demonstrada

A linguagem em exame é o Cypher, que vive nos `.cypher` deste diretório, lidos
como arquivo e passados ao motor sem alteração. É o mesmo arranjo de
`sql/alcance.sql`, que o `sqlite3` lê de arquivo.

Ler a consulta de um arquivo, em vez de embuti-la numa string, é deliberado:
é o que permite afirmar que o Cypher executado é literalmente o Cypher que se
lê no repositório.
"""

import json
import os
import shutil
import sys
import tempfile

try:
    import kuzu
except ImportError:
    print("kuzu ausente: python3 -m venv .venv && "
          ".venv/bin/pip install kuzu", file=sys.stderr)
    sys.exit(69)

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DADOS = os.path.join(RAIZ, "dados")
AQUI = os.path.dirname(os.path.abspath(__file__))


def monta(con):
    """Cria o esquema e carrega os CSV.

    ## O esquema de grafo, e a diferença com o relacional

    No relacional há TRÊS tabelas e a amizade é uma delas, com `a < b` como
    CHECK para garantir forma canônica. Aqui a amizade é um RELACIONAMENTO, e
    a direção existe no armazenamento mas não na consulta: `-[:AMIGO]-` sem
    seta atravessa os dois sentidos.

    É a diferença que paga todo o resto: o modelo relacional representa a
    aresta como dado, e o modelo de grafo a representa como estrutura.
    """
    con.execute("""
        CREATE NODE TABLE Pessoa(
            id INT64,
            nome STRING,
            cidade STRING,
            saldo_inicial DOUBLE,
            PRIMARY KEY (id)
        )
    """)

    # REL TABLE, e nao uma segunda NODE TABLE: a amizade nao e entidade, e
    # tratar relacionamento como entidade e justamente o que o modelo
    # relacional obriga a fazer.
    con.execute("CREATE REL TABLE AMIGO(FROM Pessoa TO Pessoa)")

    con.execute("CREATE REL TABLE TRANSFERIU(FROM Pessoa TO Pessoa, "
                "valor DOUBLE, data DATE)")

    # Os MESMOS CSV que alimentam o SQLite, o PostgreSQL e o BFS em Python.
    # Nenhuma transformacao: se o grafo precisasse de um formato proprio, a
    # comparacao mediria o conversor, nao os modelos.
    con.execute(f'COPY Pessoa FROM "{os.path.join(DADOS, "pessoas.csv")}" '
                '(header = true)')
    con.execute(f'COPY AMIGO FROM "{os.path.join(DADOS, "amizades.csv")}" '
                '(header = true)')
    con.execute(f'COPY TRANSFERIU FROM '
                f'"{os.path.join(DADOS, "transacoes.csv")}" (header = true)')


def le_consulta(nome):
    """Lê o .cypher do disco, sem alteração."""
    with open(os.path.join(AQUI, nome), encoding="utf-8") as fh:
        texto = fh.read()
    # O `;` final e valido em arquivo mas o driver executa UMA consulta por
    # chamada, e um `;` sobrando faz o Kuzu reclamar de instrucao vazia.
    return texto.strip().rstrip(";")


def roda(con, arquivo):
    res = con.execute(le_consulta(arquivo))
    colunas = res.get_column_names()
    linhas = []
    while res.has_next():
        linhas.append(dict(zip(colunas, res.get_next())))
    return linhas


def main():
    args = sys.argv[1:]
    pergunta = next((a for a in args if not a.startswith("-")), "alcance")
    como_json = "--json" in args

    if pergunta not in ("alcance", "caminho"):
        print("uso: roda.py {alcance|caminho} [--json]", file=sys.stderr)
        return 64

    # Banco em diretorio temporario: o Kuzu persiste em disco, e um banco
    # commitado no repositorio seria estado que divergiria dos CSV sem avisar.
    # Reconstruir do zero a cada execucao e o que garante que a resposta vem
    # dos CSV, e nao de uma carga antiga.
    tmp = tempfile.mkdtemp(prefix="qlab_kuzu_")
    try:
        con = kuzu.Connection(kuzu.Database(os.path.join(tmp, "db")))
        monta(con)

        if pergunta == "alcance":
            linhas = roda(con, "alcance.cypher")
            saida = [{"nome": l["nome"], "saltos": int(l["saltos"])}
                     for l in linhas]
            if como_json:
                print(json.dumps(saida, ensure_ascii=False, indent=2,
                                 sort_keys=True))
            else:
                print("Pessoas a até 3 saltos de amizade de Ana (Cypher):")
                print()
                print(f"{'nome':<10} {'saltos':>6}")
                print("-" * 18)
                for r in saida:
                    print(f"{r['nome']:<10} {r['saltos']:>6}")
                print("-" * 18)
                print(f"{len(saida)} pessoa(s)")
        else:
            linhas = roda(con, "caminho.cypher")
            if not linhas:
                saida = {"existe": False, "saltos": None, "caminho": []}
            else:
                l = linhas[0]
                saida = {
                    "existe": True,
                    "saltos": int(l["saltos"]),
                    "caminho": list(l["caminho"]),
                }
            if como_json:
                print(json.dumps(saida, ensure_ascii=False, indent=2,
                                 sort_keys=True))
            else:
                print("Menor caminho de amizade de Ana até Gabi (Cypher):")
                print()
                if not saida["existe"]:
                    print("  não há caminho")
                else:
                    print(f"  {' -> '.join(saida['caminho'])}")
                    print(f"  {saida['saltos']} saltos")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
