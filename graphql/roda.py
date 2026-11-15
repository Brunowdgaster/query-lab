#!/usr/bin/env python3
"""roda.py — serve o esquema GraphQL e roda as três consultas.

    .venv/bin/python graphql/roda.py aninhado    # a saida 1, e o ciclo
    .venv/bin/python graphql/roda.py alcance     # a saida 2
    .venv/bin/python graphql/roda.py selecao     # onde GraphQL ganha

## O resolver de `alcance` chama o BFS da referência, de propósito

Não é preguiça: é a demonstração. Se a travessia estivesse na linguagem, o
resolver não existiria. Reescrever o BFS aqui esconderia o ponto atrás de
código duplicado; importá-lo o deixa à vista em uma linha.
"""

import importlib.util
import json
import os
import sys

try:
    from graphql import build_schema, graphql_sync
except ImportError:
    print("graphql-core ausente: .venv/bin/pip install graphql-core",
          file=sys.stderr)
    sys.exit(69)

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AQUI = os.path.dirname(os.path.abspath(__file__))

# O MESMO modulo que produz a resposta de referencia. Ver a docstring.
_spec = importlib.util.spec_from_file_location(
    "referencia", os.path.join(RAIZ, "python", "referencia.py"))
ref = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ref)


def carrega():
    pessoas, nome_de, id_de, adj = ref.carrega()

    import csv
    with open(os.path.join(RAIZ, "dados", "transacoes.csv"),
              encoding="utf-8") as fh:
        transacoes = [
            {"de": int(r["de"]), "para": int(r["para"]),
             "valor": float(r["valor"]), "data": r["data"]}
            for r in csv.DictReader(fh)
        ]
    return pessoas, nome_de, id_de, adj, transacoes


PESSOAS, NOME_DE, ID_DE, ADJ, TRANSACOES = carrega()


def pessoa_obj(pid):
    """Um dicionario por pessoa, com os campos que o tipo promete."""
    p = PESSOAS[pid]
    return {
        "id": pid,
        "nome": p["nome"],
        "cidade": p["cidade"],
        "_id": pid,
        "saldo_inicial": float(p["saldo_inicial"]),
    }


def resolve_saldo(pessoa, _info):
    """A mesma regra de `sql/saldo.sql`, no servidor.

    Num esquema GraphQL, campo derivado e campo armazenado sao
    indistinguiveis para o cliente -- e isso e vantagem real, nao disfarce.
    """
    pid = pessoa["_id"]
    recebido = sum(t["valor"] for t in TRANSACOES if t["para"] == pid)
    enviado = sum(t["valor"] for t in TRANSACOES if t["de"] == pid)
    return pessoa["saldo_inicial"] + recebido - enviado


def resolve_amigos(pessoa, _info):
    """Espelha a aresta, que e o que o `UNION ALL` do SQL faz.

    E nota o que NAO esta aqui: nenhum controle de ciclo. O tipo `amigos:
    [Pessoa!]!` e recursivo, e nada no esquema impede que uma consulta
    aninhada volte a origem. A "saida 1" mostra isso acontecendo.
    """
    return [pessoa_obj(i) for i in sorted(ADJ[pessoa["_id"]])]


def resolve_enviadas(pessoa, _info):
    return [t for t in TRANSACOES if t["de"] == pessoa["_id"]]


def resolve_recebidas(pessoa, _info):
    return [t for t in TRANSACOES if t["para"] == pessoa["_id"]]


def resolve_alcance(_raiz, _info, de, saltos):
    """A "saida 2": o campo que RESPONDE a pergunta.

    E ele a responde chamando o BFS de python/referencia.py. A travessia esta
    em Python; o GraphQL e o envelope. O argumento `saltos` ser um dado que
    este codigo interpreta -- em vez de parte de uma expressao de consulta,
    como o `3` de `*1..3` em Cypher -- e a prova disso.
    """
    inicio = ID_DE.get(de)
    if inicio is None:
        return []
    res = ref.alcance(ADJ, inicio, saltos)
    return [
        {"nome": NOME_DE[i], "saltos": d}
        for i, d in sorted(res.items(), key=lambda kv: (kv[1], NOME_DE[kv[0]]))
    ]


def monta_schema():
    with open(os.path.join(AQUI, "esquema.graphql"), encoding="utf-8") as fh:
        schema = build_schema(fh.read())

    schema.query_type.fields["pessoa"].resolve = (
        lambda _r, _i, nome: pessoa_obj(ID_DE[nome]) if nome in ID_DE else None)
    schema.query_type.fields["pessoas"].resolve = (
        lambda _r, _i: [pessoa_obj(i) for i in sorted(PESSOAS)])
    schema.query_type.fields["alcance"].resolve = resolve_alcance

    tp = schema.type_map["Pessoa"]
    tp.fields["saldo"].resolve = resolve_saldo
    tp.fields["amigos"].resolve = resolve_amigos
    tp.fields["enviadas"].resolve = resolve_enviadas
    tp.fields["recebidas"].resolve = resolve_recebidas

    tt = schema.type_map["Transacao"]
    tt.fields["de"].resolve = lambda t, _i: pessoa_obj(t["de"])
    tt.fields["para"].resolve = lambda t, _i: pessoa_obj(t["para"])

    return schema


def executa(arquivo):
    with open(os.path.join(AQUI, arquivo), encoding="utf-8") as fh:
        consulta = fh.read()
    res = graphql_sync(monta_schema(), consulta)
    if res.errors:
        for e in res.errors:
            print(f"erro: {e.message}", file=sys.stderr)
        return None
    return res.data


def achata_aninhado(data):
    """Percorre a árvore aninhada e mostra o que ela de fato devolveu.

    Esta função existe para tornar os problemas da "saída 1" VISÍVEIS, em vez
    de descritos: a repetição, o ciclo de volta à origem, e a ausência de
    distância.
    """
    vistos = {}
    ciclos = []
    total = 0

    def anda(no, prof, trilha):
        nonlocal total
        for a in no.get("amigos") or []:
            total += 1
            nome = a["nome"]
            vistos.setdefault(nome, prof)
            if nome in trilha:
                ciclos.append(" -> ".join(trilha + [nome]))
            anda(a, prof + 1, trilha + [nome])

    raiz = data["pessoa"]
    anda(raiz, 1, [raiz["nome"]])
    return vistos, ciclos, total


def main():
    args = sys.argv[1:]
    qual = next((a for a in args if not a.startswith("-")), "alcance")
    como_json = "--json" in args

    if qual == "alcance":
        data = executa("alcance.graphql")
        if data is None:
            return 1
        saida = data["alcance"]
        if como_json:
            print(json.dumps(saida, ensure_ascii=False, indent=2,
                             sort_keys=True))
            return 0
        print("Pessoas a até 3 saltos de amizade de Ana (GraphQL, saída 2):")
        print()
        print(f"{'nome':<10} {'saltos':>6}")
        print("-" * 18)
        for r in saida:
            print(f"{r['nome']:<10} {r['saltos']:>6}")
        print("-" * 18)
        print(f"{len(saida)} pessoa(s)")
        print()
        print("E a travessia rodou em Python: o `saltos: 3` é um ARGUMENTO")
        print("que o resolver interpreta, não parte de uma expressão de")
        print("consulta como o `*1..3` do Cypher.")
        return 0

    if qual == "aninhado":
        data = executa("aninhado.graphql")
        if data is None:
            return 1
        vistos, ciclos, total = achata_aninhado(data)

        if como_json:
            print(json.dumps({
                "nos_visitados": total,
                "pessoas_distintas": len(vistos),
                "ciclos": len(ciclos),
                "primeiro_ciclo": ciclos[0] if ciclos else None,
                "tem_a_origem": "Ana" in vistos,
            }, ensure_ascii=False, indent=2, sort_keys=True))
            return 0

        print("A saída 1: aninhar `amigos` três níveis à mão")
        print()
        print(f"  nós na resposta:        {total}")
        print(f"  pessoas distintas:      {len(vistos)}")
        print(f"  a própria Ana voltou:   "
              f"{'SIM' if 'Ana' in vistos else 'não'}")
        print(f"  caminhos com repetição: {len(ciclos)}")
        if ciclos:
            print(f"  exemplo:                {ciclos[0]}")
        print()
        print(f"A resposta correta tem 5 pessoas. Esta árvore tem {total} nós")
        print(f"e {len(vistos)} nomes distintos, com a origem entre eles --")
        print("porque nada no esquema GraphQL impede o ciclo, e a resposta é")
        print("uma árvore com repetição, não um conjunto com distâncias.")
        print()
        print("Desduplicar e tirar o mínimo fica para o cliente. Em")
        print("Cypher, SQL e SPARQL, o `min(...)` é uma palavra na consulta.")
        return 0

    if qual == "selecao":
        data = executa("selecao_rica.graphql")
        if data is None:
            return 1
        if como_json:
            print(json.dumps(data, ensure_ascii=False, indent=2,
                             sort_keys=True))
            return 0
        p = data["pessoa"]
        print("Onde GraphQL ganha dos outros quatro: UMA ida ao servidor")
        print()
        print(f"  {p['nome']} ({p['cidade']}), saldo {p['saldo']:.2f}")
        print(f"  amigos: "
              f"{', '.join(a['nome'] + ' (' + a['cidade'] + ')' for a in p['amigos'])}")
        print("  enviou:")
        for t in p["enviadas"]:
            print(f"    {t['valor']:>8.2f} para {t['para']['nome']}")
        print()
        print("São três formas de dados -- escalar, lista de pessoas, lista de")
        print("transações com o destinatário embutido -- numa requisição, com")
        print("o CLIENTE escolhendo o formato.")
        print()
        print("Em SQL isso são três consultas, ou uma com JOIN que devolve")
        print("linhas repetidas e deixa remontar a hierarquia para o cliente.")
        return 0

    print("uso: roda.py {alcance|aninhado|selecao} [--json]", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
