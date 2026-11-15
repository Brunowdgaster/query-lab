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

verde()    { printf '\033[32m%s\033[0m' "$1"; }
vermelho() { printf '\033[31m%s\033[0m' "$1"; }
cinza()    { printf '\033[90m%s\033[0m' "$1"; }

passa()  { printf '  %s    %s\n' "$(verde ok)" "$1"; OK=$((OK+1)); }
falha()  { printf '  %s %s\n' "$(vermelho FALHA)" "$1"; FALHOU=$((FALHOU+1)); }
pula()   { printf '  %s  %s\n' "$(cinza pulado)" "$1"; PULADO=$((PULADO+1)); }

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

printf '\n%s\n' '=============================================================='
if [ "$PULADO" -gt 0 ]; then
    printf '  %s passaram, %s falharam, %s pulado(s)\n' \
        "$(verde "$OK")" "$FALHOU" "$(cinza "$PULADO")"
else
    printf '  %s passaram, %s falharam\n' "$(verde "$OK")" "$FALHOU"
fi
printf '%s\n\n' '=============================================================='

[ "$FALHOU" -eq 0 ]
