#!/usr/bin/env python3
"""roda.py — monta o domínio em RDF e roda as consultas SPARQL.

    .venv/bin/python sparql/roda.py alcance
    .venv/bin/python sparql/roda.py inferencia
    .venv/bin/python sparql/roda.py --ttl        # mostra o RDF gerado

## Por que o RDF é gerado, e não commitado

Os CSV em `dados/` são a fonte única do domínio, e já houve uma deriva real
neste projeto: `saldo_inicial` foi acrescentado ao esquema SQL e esquecido no
CSV, e três implementações passaram a rodar com um domínio diferente das
outras sem que nada acusasse. Hoje `python/confere_carga.py` compara as duas
fontes que ainda existem e falha se discordarem.

Um `.ttl` commitado seria uma **terceira** fonte, e derivaria igual. Então ele
é gerado a cada execução, a partir dos mesmos CSV — e `--ttl` imprime o
resultado para quem quiser ler o modelo RDF.

## O que muda ao traduzir o domínio para RDF

No relacional, uma pessoa é uma LINHA com colunas. Em RDF, é um **recurso**
identificado por IRI, e cada coluna vira uma tripla:

    :p1  rdfs:label    "Ana" .
    :p1  :cidade       "Recife" .
    :p1  :conhece      :p2 .

A consequência prática é que não existe "a tabela pessoa": existem triplas, e
a forma só aparece na consulta. É mais flexível e mais verboso, e as duas
coisas são o mesmo fato.

`rdfs:label` em vez de uma propriedade própria `:nome` é escolha deliberada:
é o vocabulário padrão para "o nome legível disto", e usar padrão onde ele
existe é o que permite a um consumidor externo entender os dados sem ler
documentação -- que é a promessa inteira do modelo.
"""

import csv
import json
import os
import sys

try:
    import rdflib
    from rdflib import Literal, Namespace, URIRef
    from rdflib.namespace import RDF, RDFS, OWL
except ImportError:
    print("rdflib ausente: .venv/bin/pip install rdflib", file=sys.stderr)
    sys.exit(69)

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DADOS = os.path.join(RAIZ, "dados")
AQUI = os.path.dirname(os.path.abspath(__file__))

Q = Namespace("http://exemplo.org/qlab#")


def monta(com_ontologia=False):
    """Constrói o grafo RDF a partir dos CSV."""
    g = rdflib.Graph()
    g.bind("", Q)
    g.bind("rdfs", RDFS)
    g.bind("owl", OWL)

    with open(os.path.join(DADOS, "pessoas.csv"), encoding="utf-8") as fh:
        pessoas = list(csv.DictReader(fh))

    def iri(pid):
        return URIRef(Q[f"p{pid}"])

    for r in pessoas:
        s = iri(r["id"])
        g.add((s, RDF.type, Q.Pessoa))
        g.add((s, RDFS.label, Literal(r["nome"])))
        g.add((s, Q.cidade, Literal(r["cidade"])))
        g.add((s, Q.saldoInicial, Literal(float(r["saldo_inicial"]))))

    with open(os.path.join(DADOS, "amizades.csv"), encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            # Gravado num sentido so, como a tabela `amizade` do SQL. A
            # consulta usa `(:conhece|^:conhece)` para atravessar os dois.
            g.add((iri(r["a"]), Q.conhece, iri(r["b"])))

    with open(os.path.join(DADOS, "transacoes.csv"), encoding="utf-8") as fh:
        for i, r in enumerate(csv.DictReader(fh), start=1):
            t = URIRef(Q[f"t{i}"])
            g.add((t, RDF.type, Q.Transacao))
            g.add((t, Q.de, iri(r["de"])))
            g.add((t, Q.para, iri(r["para"])))
            g.add((t, Q.valor, Literal(float(r["valor"]))))

    if com_ontologia:
        acrescenta_ontologia(g)

    return g


def acrescenta_ontologia(g):
    """O que nenhum dos outros dois modelos faz: declarar e deduzir.

    Esta é a demonstração que o plano do projeto pede, e a razão pela qual
    RDF existe ao lado de relacional e de grafo de propriedades.

    Declaramos duas coisas no VOCABULÁRIO, não nos dados:

      1. `:conhece` é uma propriedade SIMÉTRICA. Em RDF isso não é um
         comentário: é um fato sobre a propriedade, e um motor de inferência
         materializa o sentido inverso de TODA amizade;

      2. `:amigoIntimo` é uma SUBPROPRIEDADE de `:conhece`. Toda amizade
         íntima passa a ser, por dedução, uma amizade -- e consultas escritas
         contra `:conhece` encontram fatos gravados como `:amigoIntimo`,
         **sem que a consulta saiba que essa propriedade existe**.

    O segundo ponto é o que não tem equivalente nos outros dois modelos:

      * em SQL, acrescentar um tipo de relação exige ALTERAR as consultas (ou
        criar uma VIEW que una as tabelas);
      * em Cypher, exige mudar `-[:AMIGO]-` para `-[:AMIGO|AMIGO_INTIMO]-`
        em cada consulta que atravessa amizade.

    Em RDF a consulta não muda. O conhecimento novo entra no vocabulário, e as
    perguntas antigas passam a enxergá-lo. É isso que "inferência ontológica"
    significa em termos práticos.
    """
    g.add((Q.conhece, RDF.type, OWL.SymmetricProperty))
    g.add((Q.amigoIntimo, RDFS.subPropertyOf, Q.conhece))

    # Um fato gravado SO como :amigoIntimo, e nunca como :conhece.
    #
    # Carla (p3) e Joao (p10): a aresta que liga os DOIS COMPONENTES do grafo,
    # e que NAO esta em amizades.csv. O fato existe apenas aqui, como amizade
    # intima, para que a consulta de :conhece so o encontre POR DEDUCAO.
    #
    # A POSICAO e escolhida, e a primeira tentativa errou: o fato foi posto
    # entre Iris (p9) e Joao, e a resposta NAO MUDOU -- Iris esta a 6 saltos
    # de Ana, longe demais para a deducao entrar no limite de 3. Uma
    # demonstracao de inferencia cujo efeito nao aparece no resultado nao
    # demonstra nada.
    #
    # Carla esta a 1 salto. Ligando-a a Joao, a deducao traz DUAS pessoas
    # novas: Joao a 2 saltos e Kelly a 3 -- e a consulta nao e alterada.
    g.add((Q.p3, Q.amigoIntimo, Q.p10))


def infere(g):
    """Materializa o fecho dedutivo RDFS + OWL-RL.

    rdflib **não** faz inferência sozinho: ele é um armazenamento de triplas
    com motor SPARQL. A dedução vem do `owlrl`, que calcula o fecho e grava as
    triplas deduzidas no mesmo grafo.

    Dizer isso importa para a honestidade da demonstração: a inferência é
    capacidade do MODELO (RDF/OWL têm semântica definida para isso), e não de
    qualquer biblioteca que leia RDF. Um motor relacional não tem onde colocar
    essa semântica -- não é questão de ninguém ter implementado.
    """
    try:
        import owlrl
    except ImportError:
        return None
    antes = len(g)
    owlrl.DeductiveClosure(owlrl.OWLRL_Semantics).expand(g)
    return antes, len(g)


def le_consulta(nome):
    with open(os.path.join(AQUI, nome), encoding="utf-8") as fh:
        return fh.read()


def alcance(g):
    res = g.query(le_consulta("alcance.rq"))
    return [{"nome": str(l.nome), "saltos": int(l.saltos)} for l in res]


def main():
    args = sys.argv[1:]
    como_json = "--json" in args
    pergunta = next((a for a in args if not a.startswith("-")), "alcance")

    if "--ttl" in args:
        print(monta().serialize(format="turtle"))
        return 0

    if pergunta == "alcance":
        saida = alcance(monta())
        if como_json:
            print(json.dumps(saida, ensure_ascii=False, indent=2,
                             sort_keys=True))
        else:
            print("Pessoas a até 3 saltos de amizade de Ana (SPARQL):")
            print()
            print(f"{'nome':<10} {'saltos':>6}")
            print("-" * 18)
            for r in saida:
                print(f"{r['nome']:<10} {r['saltos']:>6}")
            print("-" * 18)
            print(f"{len(saida)} pessoa(s)")
        return 0

    if pergunta == "inferencia":
        g = monta(com_ontologia=True)

        # ANTES da inferencia: a consulta de :conhece NAO ve a amizade intima.
        antes = alcance(g)
        nomes_antes = {r["nome"] for r in antes}

        n = infere(g)
        if n is None:
            print("owlrl ausente: .venv/bin/pip install owlrl",
                  file=sys.stderr)
            return 69

        depois = alcance(g)
        nomes_depois = {r["nome"] for r in depois}

        if como_json:
            print(json.dumps({
                "triplas_antes": n[0],
                "triplas_depois": n[1],
                "antes": sorted(nomes_antes),
                "depois": sorted(nomes_depois),
                "deduzidos": sorted(nomes_depois - nomes_antes),
            }, ensure_ascii=False, indent=2, sort_keys=True))
            return 0

        print("O que o RDF faz e os outros dois modelos não fazem")
        print()
        print("Declarado no VOCABULÁRIO, não nos dados:")
        print("  :conhece      a  owl:SymmetricProperty")
        print("  :amigoIntimo  rdfs:subPropertyOf  :conhece")
        print()
        print("E um único fato gravado SÓ como :amigoIntimo, ligando os")
        print("dois componentes do grafo:")
        print("  :p3 (Carla)  :amigoIntimo  :p10 (Joao)")
        print()
        print(f"Triplas: {n[0]} declaradas -> {n[1]} após a dedução")
        print()
        print(f"  antes da inferência:  {', '.join(sorted(nomes_antes))}")
        print(f"  depois:               {', '.join(sorted(nomes_depois))}")
        print()
        novos = sorted(nomes_depois - nomes_antes)
        if novos:
            print(f"  apareceram por DEDUÇÃO: {', '.join(novos)}")
            print()
            print("  A consulta em alcance.rq NÃO foi alterada, e não sabe")
            print("  que :amigoIntimo existe. Em SQL isso exigiria mudar a")
            print("  consulta ou criar uma VIEW; em Cypher, trocar")
            print("  -[:AMIGO]- por -[:AMIGO|AMIGO_INTIMO]- em cada consulta.")
        else:
            print("  nenhum nome novo: a inferência não mudou a resposta")
        return 0

    print("uso: roda.py {alcance|inferencia} [--json] [--ttl]",
          file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
