#!/usr/bin/env python3
"""confere_carga.py — os dois carregadores do domínio concordam?

    python3 python/confere_carga.py

## Por que este arquivo existe

O domínio tem **duas** formas de entrar num motor:

  * os CSV em `dados/`, que o Python, o Kuzu (Cypher) e o rdflib (SPARQL)
    leem direto;
  * os `INSERT` literais de `sql/carga.sql`, que o SQLite e o PostgreSQL usam.

A duplicação é deliberada e está explicada em `sql/carga.sql`: `.import` do
SQLite e `COPY` do PostgreSQL são comandos de **ferramenta**, não de
linguagem, e divergem — então um projeto que compara SQL ANSI entre dois
motores não pode carregar por eles.

Mas duas fontes da mesma verdade derivam. E derivaram: a coluna
`saldo_inicial` foi acrescentada ao esquema e ao `carga.sql` e **não ao CSV**.
O sintoma apareceu só quando o Kuzu tentou ler o CSV e achou 3 campos onde o
esquema prometia 4 -- ou seja, três implementações já rodavam com um domínio
diferente do das outras, e nada acusava.

Este script é a correção estrutural: ele compara as duas fontes linha por
linha e falha se discordarem. Sem ele, a disciplina de manter as duas em
sincronia é só boa intenção.
"""

import csv
import os
import re
import sys
from decimal import Decimal

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DADOS = os.path.join(RAIZ, "dados")
CARGA = os.path.join(RAIZ, "sql", "carga.sql")


def do_csv():
    """As três relações, como os CSV as declaram."""
    def le(nome):
        with open(os.path.join(DADOS, nome), encoding="utf-8") as fh:
            return list(csv.DictReader(fh))

    pessoas = {
        (int(r["id"]), r["nome"], r["cidade"], Decimal(r["saldo_inicial"]))
        for r in le("pessoas.csv")
    }
    amizades = {(int(r["a"]), int(r["b"])) for r in le("amizades.csv")}
    transacoes = {
        (int(r["de"]), int(r["para"]), Decimal(r["valor"]), r["data"])
        for r in le("transacoes.csv")
    }
    return pessoas, amizades, transacoes


def do_sql():
    """As mesmas três relações, como `sql/carga.sql` as declara.

    O parse é por expressão regular, e isso é uma escolha consciente de
    escopo: o arquivo é gerado e mantido à mão, com uma forma fixa de
    `VALUES (...)`. Um parser de SQL de verdade seria o instrumento certo se o
    arquivo fosse arbitrário -- e introduziria uma dependência para verificar
    uma dúzia de linhas.

    O risco da regex é aceitar algo que o banco rejeitaria. Isso está coberto
    de outro jeito: a suíte carrega o `carga.sql` nos DOIS motores de verdade
    antes de chegar aqui. Se a forma mudar, o banco reclama primeiro.
    """
    with open(CARGA, encoding="utf-8") as fh:
        texto = fh.read()

    # Remove comentarios de linha para que `--` dentro de texto explicativo
    # nao seja confundido com dado.
    texto = re.sub(r"--[^\n]*", "", texto)

    def bloco(tabela):
        m = re.search(
            r"INSERT\s+INTO\s+" + tabela + r"\s*\([^)]*\)\s*VALUES(.*?);",
            texto, re.S | re.I)
        if not m:
            raise SystemExit(f"nao achei o INSERT de {tabela} em sql/carga.sql")
        return re.findall(r"\(([^)]*)\)", m.group(1))

    def campos(linha):
        return [c.strip().strip("'") for c in linha.split(",")]

    pessoas = set()
    for linha in bloco("pessoa"):
        c = campos(linha)
        pessoas.add((int(c[0]), c[1], c[2], Decimal(c[3])))

    amizades = set()
    for linha in bloco("amizade"):
        c = campos(linha)
        amizades.add((int(c[0]), int(c[1])))

    transacoes = set()
    for linha in bloco("transacao"):
        c = campos(linha)
        # c[0] e o id da transacao, que o CSV nao tem: o CSV e a ordem das
        # linhas, e o SQL precisa da chave explicita porque o esquema e ANSI e
        # nao tem sequencia. Entao a comparacao ignora o id, de proposito.
        transacoes.add((int(c[1]), int(c[2]), Decimal(c[3]), c[4]))

    return pessoas, amizades, transacoes


def main():
    csv_p, csv_a, csv_t = do_csv()
    sql_p, sql_a, sql_t = do_sql()

    falhou = 0

    for nome, a, b in (
        ("pessoa", csv_p, sql_p),
        ("amizade", csv_a, sql_a),
        ("transacao", csv_t, sql_t),
    ):
        if a == b:
            print(f"  ok    {nome}: {len(a)} linha(s) idênticas nas duas fontes")
            continue

        falhou += 1
        print(f"  FALHA {nome}: as duas fontes discordam")
        so_csv = sorted(a - b, key=str)
        so_sql = sorted(b - a, key=str)
        for linha in so_csv[:5]:
            print(f"        só no CSV: {linha}")
        for linha in so_sql[:5]:
            print(f"        só no SQL: {linha}")

    print()
    if falhou:
        print(f"  {falhou} relação(ões) divergem entre dados/ e sql/carga.sql")
        return 1

    print("  as duas fontes do domínio concordam")
    return 0


if __name__ == "__main__":
    sys.exit(main())
