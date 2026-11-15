#!/usr/bin/env bash
# verifica.sh — a suíte do p10-query-lab.
#
# A tese do projeto é que a MESMA pergunta, respondida em oito linguagens
# sobre três modelos de dados, tem de dar a MESMA resposta. Este script é o
# que torna isso verificável em vez de afirmado.
#
# Nunca `set -e`: ele aborta no primeiro `[ ]` falso e a suíte vira "para no
# primeiro erro" em vez de "relata todos". Cada caso checa seu próprio
# retorno.
set -uo pipefail

cd "$(dirname "$0")"

OK=0
FALHOU=0
PULADO=0

# QLAB_EXIGE=1 transforma todo "pulado" em FALHA.
#
# Local, pular e certo: o projeto depende de bancos que nao cabem em qualquer
# maquina. No CI, pular e PERIGOSO -- se o Postgres nao subir, a suite
# passaria verde tendo verificado um terco do que diz verificar, e o log
# esconderia isso entre os ok.
#
# E a mesma licao do job do AutoHotkey no p12: falhar ALTO quando a
# dependencia nao apareceu, em vez de deixar o teste reportar a ausencia como
# se fosse resultado.
EXIGE="${QLAB_EXIGE:-0}"

verde()    { printf '\033[32m%s\033[0m' "$1"; }
vermelho() { printf '\033[31m%s\033[0m' "$1"; }
cinza()    { printf '\033[90m%s\033[0m' "$1"; }

passa()  { printf '  %s    %s\n' "$(verde ok)" "$1"; OK=$((OK+1)); }
falha()  { printf '  %s %s\n' "$(vermelho FALHA)" "$1"; FALHOU=$((FALHOU+1)); }
pula() {
    if [ "$EXIGE" = "1" ]; then
        printf '  %s  %s\n' "$(vermelho FALHA)" "$1 (QLAB_EXIGE=1)"
        FALHOU=$((FALHOU+1))
    else
        printf '  %s  %s\n' "$(cinza pulado)" "$1"
        PULADO=$((PULADO+1))
    fi
}

secao() { printf '\n%s\n' "$(cinza "$1")"; }

# `tem` existe para a suíte PULAR, e não falhar, quando um motor não está
# instalado. É deliberado: o p10 depende de bancos que não cabem todos em
# qualquer máquina, e uma suíte que falha por ausência de Oracle não
# distingue "quebrou" de "não tem".
tem() { command -v "$1" >/dev/null 2>&1; }

printf '\n%s\n' '=============================================================='
printf '%s\n' 'query-lab — a mesma pergunta, oito linguagens'
printf '%s\n' '=============================================================='

# ---------------------------------------------------------------------------
secao 'python/referencia.py — a resposta de referência'

if ! tem python3; then
    pula 'python3 ausente: a referência não pode ser conferida'
else
    saida=$(python3 python/referencia.py alcance 2>&1); ret=$?
    if [ $ret -eq 0 ] && printf '%s' "$saida" | grep -q '5 pessoa'; then
        passa 'alcance a 3 saltos acha 5 pessoas'
    else
        falha "alcance: retorno=$ret"
    fi

    # Gabi esta a 4 saltos e TEM de ficar fora. E o teste que o limite de 3
    # existe para fazer: um off-by-one na contagem a incluiria.
    if ! printf '%s' "$saida" | grep -q 'Gabi'; then
        passa 'Gabi (4 saltos) fica fora do limite de 3'
    else
        falha 'Gabi apareceu dentro do limite de 3'
    fi

    # Joao, Kelly e Lucas estao em componente separado: nenhum caminho.
    if ! printf '%s' "$saida" | grep -qE 'Joao|Kelly|Lucas'; then
        passa 'o componente desconexo fica fora'
    else
        falha 'alguem do componente desconexo apareceu'
    fi

    saida=$(python3 python/referencia.py caminho 2>&1); ret=$?
    if [ $ret -eq 0 ] && printf '%s' "$saida" | grep -q '4 saltos'; then
        passa 'menor caminho até Gabi tem 4 saltos'
    else
        falha "caminho: retorno=$ret"
    fi

    # A referencia gravada tem de ser IGUAL a recalculada. Se divergir, o
    # arquivo esperado esta velho -- e todas as outras implementacoes estariam
    # sendo conferidas contra uma resposta obsoleta.
    atual=$(python3 python/referencia.py alcance --json 2>/dev/null)
    if [ "$atual" = "$(cat dados/esperado/alcance.json)" ]; then
        passa 'dados/esperado/alcance.json está em dia'
    else
        falha 'o esperado gravado divergiu: rode --gravar'
    fi
fi

# ---------------------------------------------------------------------------
secao 'sql/ — SQL ANSI, o MESMO arquivo em dois motores'

esperado_sql='Bruno|1
Carla|1
Diego|2
Elisa|2
Fabio|3'

if ! tem sqlite3; then
    pula 'sqlite3 ausente'
else
    db=$(mktemp -u).db
    if sqlite3 "$db" < sql/esquema.sql 2>/dev/null \
       && sqlite3 "$db" < sql/carga.sql 2>/dev/null; then
        passa 'o esquema ANSI carrega no SQLite'
    else
        falha 'o esquema não carregou no SQLite'
    fi

    obtido=$(sqlite3 -noheader -list "$db" < sql/alcance.sql 2>&1)
    if [ "$obtido" = "$esperado_sql" ]; then
        passa 'o CTE recursivo bate com a referência (SQLite)'
    else
        falha "SQLite divergiu: $(printf '%s' "$obtido" | tr '\n' ' ')"
    fi
    rm -f "$db"
fi

if ! tem psql; then
    pula 'psql ausente'
elif ! sudo -n -u postgres psql -tAc 'select 1' >/dev/null 2>&1; then
    pula 'postgres não responde (service postgresql start)'
else
    pg() { sudo -n -u postgres psql -q -v ON_ERROR_STOP=1 -d qlab "$@"; }

    sudo -n -u postgres psql -q -c 'DROP DATABASE IF EXISTS qlab' \
        -c 'CREATE DATABASE qlab' >/dev/null 2>&1

    if pg -f sql/esquema.sql >/dev/null 2>&1 \
       && pg -f sql/carga.sql >/dev/null 2>&1; then
        passa 'o MESMO esquema carrega no PostgreSQL, sem alteração'
    else
        falha 'o esquema não carregou no PostgreSQL'
    fi

    obtido=$(sudo -n -u postgres psql -tA -F'|' -d qlab -f sql/alcance.sql 2>&1)
    if [ "$obtido" = "$esperado_sql" ]; then
        passa 'o MESMO .sql dá a MESMA resposta no PostgreSQL'
    else
        falha "PostgreSQL divergiu: $(printf '%s' "$obtido" | tr '\n' ' ')"
    fi

    # -----------------------------------------------------------------------
    secao 'plpgsql/ — a procedure, e a atomicidade'

    if pg -f plpgsql/transferir.sql >/dev/null 2>&1; then
        passa 'a procedure compila'
    else
        falha 'a procedure não compila'
    fi

    # O retorno capturado ANTES de qualquer cano: medir `$?` depois de um
    # `| grep` mede o grep. Esse erro ja apareceu tres vezes neste portfolio.
    saida=$(pg -f plpgsql/testa.sql 2>&1); ret=$?
    if [ $ret -eq 0 ] && printf '%s' "$saida" | grep -q '8 passaram, 0 falharam'; then
        passa 'os 8 testes da procedure passam'
    else
        falha "testes da procedure: retorno=$ret"
        printf '%s\n' "$saida" | sed 's/^/        /' | tail -6
    fi

    # QL004 e capturavel por WHEN OTHERS, e P0004 (assert_failure) nao e.
    # Este teste existe porque a primeira versao usava P0001..P0004 achando
    # que a classe P0 era livre -- e tres das quatro colisoes passaram nos
    # testes, porque o teste conferia o mesmo codigo errado.
    if ! grep -q "ERRCODE = 'P000" plpgsql/transferir.sql; then
        passa 'nenhum ERRCODE da classe P0 (colidiria com os do PostgreSQL)'
    else
        falha 'voltou a usar P0***: P0004 é assert_failure e WHEN OTHERS não pega'
    fi
fi

# ---------------------------------------------------------------------------
secao 'dados/ — as duas fontes do dominio concordam?'

# Este teste existe porque elas JA divergiram: `saldo_inicial` foi
# acrescentado ao esquema SQL e esquecido no CSV, e tres implementacoes
# passaram a rodar com um dominio diferente das outras sem que nada acusasse.
# O sintoma apareceu so quando o Kuzu achou 3 campos onde o esquema prometia
# 4 -- por acidente, nao por verificacao.
if ! tem python3; then
    pula 'python3 ausente'
else
    saida=$(python3 python/confere_carga.py 2>&1); ret=$?
    if [ $ret -eq 0 ]; then
        passa 'dados/*.csv e sql/carga.sql declaram o mesmo dominio'
    else
        falha 'as duas fontes do dominio divergem'
        printf '%s\n' "$saida" | sed 's/^/        /' | tail -6
    fi
fi

# ---------------------------------------------------------------------------
# Os tres motores embarcados vivem num venv, porque o Ubuntu 26.04 marca o
# Python do sistema como externally-managed (PEP 668) e recusa `pip install`
# global. O venv e gitignorado: ele e ambiente, nao codigo.
PY=.venv/bin/python

secao 'cypher/ — travessia como primitiva da linguagem'

if [ ! -x "$PY" ]; then
    pula 'venv ausente: python3 -m venv .venv && .venv/bin/pip install kuzu rdflib graphql-core owlrl'
elif ! "$PY" -c 'import kuzu' 2>/dev/null; then
    pula 'kuzu ausente no venv'
else
    obtido=$("$PY" cypher/roda.py alcance --json 2>&1)
    if [ "$obtido" = "$(cat dados/esperado/alcance.json)" ]; then
        passa 'Cypher da a MESMA resposta, byte a byte'
    else
        falha "Cypher divergiu: $(printf '%s' "$obtido" | tr -d ' \n' | head -c 90)"
    fi

    # O caminho e VALIDADO, nao comparado: medido que `SHORTEST` e `ALL
    # SHORTEST` devolvem caminhos DIFERENTES e os dois corretos, porque o
    # menor caminho nao e unico. Comparar literalmente testaria a ordem
    # interna do motor e reprovaria resposta certa.
    if "$PY" cypher/roda.py caminho --json 2>/dev/null \
         | python3 python/valida_caminho.py --saltos 4 --rotulo Cypher; then
        :
    else
        FALHOU=$((FALHOU+1))
    fi
    OK=$((OK+1))
fi

secao 'sparql/ — property path, e a inferencia que os outros nao fazem'

if [ ! -x "$PY" ] || ! "$PY" -c 'import rdflib' 2>/dev/null; then
    pula 'rdflib ausente no venv'
else
    obtido=$("$PY" sparql/roda.py alcance --json 2>&1)
    if [ "$obtido" = "$(cat dados/esperado/alcance.json)" ]; then
        passa 'SPARQL da a MESMA resposta, byte a byte'
    else
        falha "SPARQL divergiu: $(printf '%s' "$obtido" | tr -d ' \n' | head -c 90)"
    fi

    # SPARQL 1.1 NAO tem caminho limitado: `{1,3}` e erro de sintaxe, porque o
    # quantificador saiu da recomendacao final. Este teste trava a afirmacao:
    # se uma versao futura do rdflib aceitar, o teste falha e o README precisa
    # ser corrigido -- em vez de ficar desatualizado em silencio.
    if "$PY" -c '
import sys, rdflib
g = rdflib.Graph()
g.parse(data="@prefix : <http://e/> . :a :p :b .", format="turtle")
try:
    g.query("SELECT ?x WHERE { <http://e/a> <http://e/p>{1,3} ?x }")
    sys.exit(1)
except Exception:
    sys.exit(0)
' 2>/dev/null; then
        passa 'SPARQL 1.1 recusa {1,3}, como o padrao manda'
    else
        falha 'o motor ACEITOU {1,3}: o README afirma que o padrao nao tem'
    fi

    # A inferencia tem de MUDAR a resposta, senao nao demonstra nada. A
    # primeira versao punha o fato deduzido a 6 saltos da origem, longe demais
    # para entrar no limite de 3, e a resposta nao mudava.
    saida=$("$PY" sparql/roda.py inferencia --json 2>&1)
    if printf '%s' "$saida" | grep -q '"Joao"' \
       && printf '%s' "$saida" | grep -q '"Kelly"'; then
        passa 'a inferencia traz Joao e Kelly por DEDUCAO'
    else
        falha 'a inferencia nao mudou a resposta'
    fi
fi

secao 'graphql/ — o que o modelo NAO expressa'

if [ ! -x "$PY" ] || ! "$PY" -c 'import graphql' 2>/dev/null; then
    pula 'graphql-core ausente no venv'
else
    # A "saida 2" acerta, e e justamente o ponto: ela acerta porque a
    # travessia roda em Python.
    obtido=$("$PY" graphql/roda.py alcance --json 2>&1)
    if [ "$obtido" = "$(cat dados/esperado/alcance.json)" ]; then
        passa 'o campo alcance() acerta -- resolvendo em Python'
    else
        falha 'o campo alcance() divergiu'
    fi

    # A "saida 1" tem de ERRAR, e o teste verifica o erro ESPERADO. Se o
    # aninhamento a mao passasse a dar a resposta certa, a tese do README
    # estaria errada e este teste e que avisaria.
    saida=$("$PY" graphql/roda.py aninhado --json 2>&1)
    if printf '%s' "$saida" | grep -q '"tem_a_origem": true'; then
        passa 'o aninhamento a mao traz a ORIGEM de volta (ciclo)'
    else
        falha 'o aninhamento nao reproduziu o ciclo que o README descreve'
    fi

    if printf '%s' "$saida" | grep -q '"ciclos": [1-9]'; then
        passa 'e tem caminho com repeticao, que nenhum tipo impede'
    else
        falha 'nenhum ciclo no aninhamento: o README descreve outro resultado'
    fi

    # A selecao rica tem de funcionar: e o lado em que GraphQL GANHA, e
    # mostrar so o lado em que ele perde seria escolher a prova.
    if "$PY" graphql/roda.py selecao --json 2>/dev/null \
         | grep -q '"saldo": 834.75'; then
        passa 'a selecao rica traz 3 formas de dados numa requisicao'
    else
        falha 'a selecao rica falhou'
    fi
fi

printf '\n%s\n' '=============================================================='
if [ "$PULADO" -gt 0 ]; then
    printf '  %s passaram, %s falharam, %s pulado(s)\n' \
        "$(verde "$OK")" "$FALHOU" "$(cinza "$PULADO")"
else
    printf '  %s passaram, %s falharam\n' "$(verde "$OK")" "$FALHOU"
fi
printf '%s\n\n' '=============================================================='

[ "$FALHOU" -eq 0 ]
