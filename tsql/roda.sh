#!/usr/bin/env bash
# roda.sh — sobe o SQL Server num contêiner e executa um .sql nele.
#
#     ./roda.sh                 sobe o contêiner, cria o banco, roda os testes
#     ./roda.sh arquivo.sql     executa só esse arquivo
#     ./roda.sh --derruba       para e remove o contêiner
#
# ## Por que contêiner, e por que esta edição
#
# O SQL Server não roda nativamente em WSL2 sem systemd, e instalar o pacote
# `mssql-server` exigiria uma VM. A imagem oficial resolve, e a edição
# **Developer** é gratuita para desenvolvimento e teste -- é a mesma
# funcionalidade da Enterprise, licenciada para não-produção.
#
# A imagem tem ~1,5 GB, e está registrada na lista de remoção do
# `poliglota/AMBIENTE.md` junto com o volume nomeado que ela cria. O volume
# importa: `docker rmi` não o apaga, e um banco removido deixando o volume
# atrás é a forma mais comum de "removi e o disco não voltou".
#
# ## A senha
#
# Está no código de propósito, e isto é um banco de teste que só escuta em
# localhost. Uma senha em repositório é um defeito real quando o banco é real;
# aqui o alerta seria ruído, e esconder a senha num `.env` daria a impressão
# de que há algo a proteger.
set -uo pipefail

NOME=p10-mssql
SENHA='QueryLab!2026pg'
IMAGEM=mcr.microsoft.com/mssql/server:2022-latest
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"

# O sqlcmd 18+ exige TLS, e o certificado do contêiner é autoassinado: `-C`
# confia nele. Sem `-C` a conexão falha com um erro de certificado que não
# menciona certificado.
sqlcmd() {
    docker exec -i "$NOME" /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "$SENHA" -C -b "$@"
}

derruba() {
    docker rm -f "$NOME" >/dev/null 2>&1
    echo "contêiner $NOME removido (o volume p10-mssql-dados fica)"
}

[ "${1:-}" = '--derruba' ] && { derruba; exit 0; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "docker ausente ou sem permissão" >&2
    exit 127
fi

# Sobe só se não estiver rodando. Reaproveitar o contêiner entre execuções
# economiza os ~15 s de inicialização, e o `docker start` restaura o volume.
if ! docker ps --format '{{.Names}}' | grep -qx "$NOME"; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$NOME"; then
        docker start "$NOME" >/dev/null
    else
        docker run -d --name "$NOME" \
            -e ACCEPT_EULA=Y \
            -e MSSQL_SA_PASSWORD="$SENHA" \
            -e MSSQL_PID=Developer \
            -p 11433:1433 \
            -v p10-mssql-dados:/var/opt/mssql \
            "$IMAGEM" >/dev/null || exit 1
    fi

    # Espera ATIVA, com limite. Um `sleep 30` fixo seria mais lento no caso
    # bom e insuficiente no caso ruim -- e, pior, um timeout não distingue
    # "o banco travou" de "o banco é mais lento que o meu limite".
    pronto=0
    for _ in $(seq 1 60); do
        if sqlcmd -Q 'SELECT 1' >/dev/null 2>&1; then pronto=1; break; fi
        sleep 2
    done
    [ "$pronto" = 1 ] || { echo "o SQL Server não respondeu em 120 s" >&2; exit 1; }
fi

if [ $# -gt 0 ]; then
    sqlcmd -i "/dev/stdin" < "$1"
    exit $?
fi

# Sem argumento: o ciclo completo.
#
# O esquema é copiado para dentro do contêiner por stdin em vez de montado,
# porque montar /mnt/c num contêiner adiciona a penalidade do DrvFs a cada
# leitura -- medida em outro projeto deste portfólio como 98 s contra 1,7 s.
# O banco, recriado do zero a cada execucao.
#
# O `DROP` vem antes, e depois dele os ARQUIVOS SAO APAGADOS A MAO. Esse
# segundo passo parece redundante e nao e, por um motivo que foi medido neste
# projeto:
#
# A VM do WSL2 se desliga quando nenhuma sessao a mantem aberta, e leva o
# daemon do Docker e todos os conteineres com ela -- sem SIGTERM, sem
# desligamento ordenado. Medido aqui: o conteiner subiu 23:54:55, o log para
# 23:55:24 e o processo morre 23:56:22, 9 s depois de o WSL reiniciar, com
# exit 255 e NENHUMA mensagem de erro.
#
# A consequencia e que o `master.mdf` pode nao ter registrado o `qlab` que o
# `qlab.mdf` no disco ja representa. Entao `DB_ID('qlab')` da NULL -- o banco
# nao existe -- e o `CREATE DATABASE` falha com erro 5170, "Cannot create file
# ... because it already exists". Um estado em que nem criar nem apagar
# funciona, pelo caminho normal.
#
# Apagar os arquivos orfaos resolve, e e seguro porque este banco e recriado
# a cada execucao de qualquer forma.
sqlcmd -Q "IF DB_ID('qlab') IS NOT NULL BEGIN ALTER DATABASE qlab SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE qlab; END" >/dev/null 2>&1
docker exec "$NOME" bash -c 'rm -f /var/opt/mssql/data/qlab*.mdf /var/opt/mssql/data/qlab*.ldf' 2>/dev/null
sqlcmd -Q "CREATE DATABASE qlab;" || exit 1

# O esquema ANSI, SEM alteração -- é o mesmo arquivo que roda em SQLite e
# PostgreSQL. Que ele rode em três motores é a afirmação que `sql/esquema.sql`
# faz, e aqui ela é testada no terceiro.
{ echo 'USE qlab;'; echo 'GO'; cat "$RAIZ/sql/esquema.sql"; echo; echo 'GO'; } \
    | sqlcmd -i /dev/stdin || exit 1

{ echo 'USE qlab;'; echo 'GO'; cat "$RAIZ/sql/carga.sql"; echo; echo 'GO'; } \
    | sqlcmd -i /dev/stdin || exit 1

{ echo 'USE qlab;'; echo 'GO'; cat "$AQUI/transferir.sql"; } \
    | sqlcmd -i /dev/stdin || exit 1

{ echo 'USE qlab;'; echo 'GO'; cat "$AQUI/testa.sql"; } \
    | sqlcmd -i /dev/stdin
