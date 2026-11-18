#!/usr/bin/env bash
# roda.sh — sobe o Oracle Database Free num contêiner e roda o PL/SQL nele.
#
#     ./roda.sh                 sobe, cria o esquema, roda os testes
#     ./roda.sh --derruba       para e remove o contêiner
#
# ## A edição, e por que ela é gratuita
#
# **Oracle Database 23ai Free.** É gratuita para qualquer uso, inclusive
# produção, com limites: 12 GB de dados de usuário, 2 GB de RAM, 2 núcleos.
# Nenhum limite estorva este projeto, que tem 33 linhas de dados.
#
# É a sucessora da Express Edition (XE), e não exige cadastro nem chave --
# `docker pull container-registry.oracle.com/database/free` funciona sem login,
# o que foi verificado aqui.
#
# ## O tamanho real, medido e não estimado
#
# A imagem tem **13,8 GB**. O `AMBIENTE.md` deste portfólio dizia "~2,5 GB"
# antes de ela ser baixada, e o número estava errado por cinco vezes -- a
# correção está registrada lá com a medição ao lado, porque uma lista de
# remoção com número inventado não serve para decidir nada.
#
# Ela e o volume que o contêiner cria estão na lista de remoção.
#
# ## A senha
#
# Está no código de propósito: é um banco de teste que só escuta em localhost.
# Esconder a senha daria a impressão de que há algo a proteger.
set -uo pipefail

NOME=p10-oracle
SENHA=QueryLab2026
IMAGEM=container-registry.oracle.com/database/free:latest
# O PDB (pluggable database) padrão desta imagem. O Oracle 12c+ separa o
# container database (CDB, aqui `FREE`) dos bancos plugáveis dentro dele, e é
# no PDB que o esquema de aplicação vive -- conectar no CDB e criar tabela lá
# funciona e é errado.
PDB=FREEPDB1
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(dirname "$AQUI")"

derruba() {
    docker rm -f "$NOME" >/dev/null 2>&1
    echo "contêiner $NOME removido"
}

[ "${1:-}" = '--derruba' ] && { derruba; exit 0; }

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo 'docker ausente ou sem permissão' >&2
    exit 127
fi

# O SQL Server e o Oracle NÃO cabem juntos nesta máquina.
#
# Medido: o WSL2 expõe 3,8 GB, o SQL Server reserva ~2,6 GB e o Oracle Free
# pede 2 GB. Então o Oracle para o outro antes de subir, e o `tsql/roda.sh`
# faz o mesmo em relação a este.
#
# Parar não apaga nada: o volume de cada um sobrevive, e a próxima execução
# de qualquer dos dois reaproveita.
docker stop p10-mssql >/dev/null 2>&1 || true

if ! docker ps --format '{{.Names}}' | grep -qx "$NOME"; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$NOME"; then
        docker start "$NOME" >/dev/null
    else
        docker run -d --name "$NOME" \
            -e ORACLE_PWD="$SENHA" \
            -p 11521:1521 \
            "$IMAGEM" >/dev/null || exit 1
    fi
fi

# A espera é por uma CONSULTA que responde, e não pelo log nem pela porta.
#
# As duas alternativas mais obvias estao erradas, e as duas foram tentadas
# aqui antes desta versao:
#
# **A porta 1521** abre antes de o banco aceitar conexao. Um teste que so
# verificasse a porta comecaria a rodar SQL contra um listener sem instancia,
# e o erro (ORA-12514) nao diz "ainda subindo", diz "servico nao existe".
#
# **O log** tem dois problemas. O primeiro: `docker logs` traz o historico
# INTEIRO, e num `docker start` a mensagem "DATABASE IS READY TO USE" da
# primeira subida ainda esta la -- medido, duas ocorrencias depois de um
# reinicio. A espera terminaria na hora, antes de o banco estar pronto.
#
# O segundo problema do log e mais interessante, e custou 600 s de espera
# inutil numa execucao:
#
#     if docker logs "$NOME" 2>&1 | grep -q 'DATABASE IS READY TO USE'
#
# Esta linha e FALSA mesmo quando o grep ACHA. O `grep -q` sai no primeiro
# casamento e fecha o cano; o `docker logs`, que ainda estava escrevendo,
# morre de SIGPIPE com codigo 141; e o `set -o pipefail` no topo deste arquivo
# faz o status do pipeline ser o do `docker logs`, nao o do `grep`. O `if`
# recebe 141 -- falha -- e descarta justamente o sinal que encontrou.
#
# E a mesma licao que este portfolio ja registrou pelo outro lado ("capture
# `$?` ANTES de qualquer cano"), agora invertida: com `pipefail`, um comando
# que sai cedo de proposito faz o comando anterior falhar.
#
# A consulta resolve os tres: ela so responde quando o banco responde, nao le
# historico, e nao tem cano.
#
# A primeira subida cria o CDB e leva ~78 s nesta máquina; as seguintes são
# mais rápidas porque o volume já tem o banco.
pronto=0
for _ in $(seq 1 100); do
    if printf 'SELECT 1 FROM DUAL;
EXIT
'        | docker exec -i "$NOME" sqlplus -S              "sys/$SENHA@localhost:1521/$PDB" as sysdba >/dev/null 2>&1; then
        pronto=1
        break
    fi
    sleep 6
done
[ "$pronto" = 1 ] || {
    echo 'o Oracle não ficou pronto em 600 s' >&2
    docker logs "$NOME" 2>&1 | tail -5 >&2
    exit 1
}

sql_sys() {
    docker exec -i "$NOME" sqlplus -S \
        "sys/$SENHA@localhost:1521/$PDB" as sysdba
}
sql_qlab() {
    docker exec -i "$NOME" sqlplus -S "qlab/$SENHA@localhost:1521/$PDB"
}

# O usuário da aplicação, recriado a cada execução.
#
# `DROP USER ... CASCADE` apaga o esquema inteiro, que é o equivalente Oracle
# do `DROP DATABASE` dos outros dois -- no Oracle, "usuário" e "esquema" são
# a mesma coisa, e é uma diferença conceitual que vale saber: não há
# `CREATE DATABASE` para isto.
#
# Os erros são ignorados na primeira execução, quando o usuário ainda não
# existe -- e o `WHENEVER SQLERROR` fica DESLIGADO só neste trecho, por isso.
sql_sys >/dev/null 2>&1 <<'SQL'
SET FEEDBACK OFF
DROP USER qlab CASCADE;
EXIT
SQL

sql_sys <<SQL || exit 1
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
CREATE USER qlab IDENTIFIED BY "$SENHA" QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE TO qlab;
EXIT
SQL

# O esquema ANSI, SEM alteração -- é o mesmo arquivo que roda em SQLite,
# PostgreSQL e SQL Server. Se ele precisar de uma linha de Oracle, este
# comando falha e a afirmação do cabeçalho de `sql/esquema.sql` estava errada.
{
    echo 'SET FEEDBACK OFF'
    echo 'WHENEVER SQLERROR EXIT SQL.SQLCODE'
    cat "$RAIZ/sql/esquema.sql"
    echo
    echo 'EXIT'
} | sql_qlab || exit 1

# A carga, DERIVADA de sql/carga.sql em vez de escrita à mão.
#
# O Oracle não aceita `VALUES` com várias linhas -- recurso do SQL-92 que os
# outros três motores têm. Escrever um segundo arquivo de carga criaria duas
# fontes para os mesmos dados, e este projeto já pagou por isso: `saldo_inicial`
# foi acrescentado ao esquema e esquecido no CSV, e três implementações rodaram
# com um domínio diferente sem que nada acusasse.
#
# Então `traduz_carga.py` quebra as tuplas em um INSERT por linha, a partir da
# mesma fonte.
# `mktemp` e nao um nome fixo em /tmp: duas execucoes simultaneas (a suite
# local e um CI na mesma maquina, por exemplo) escreveriam no mesmo arquivo, e
# a segunda leria a carga da primeira pela metade. O `trap` apaga na saida,
# inclusive quando o script falha no meio.
CARGA=$(mktemp -t carga_oracle.XXXXXX.sql)
trap 'rm -f "$CARGA"' EXIT
python3 "$AQUI/traduz_carga.py" > "$CARGA" || exit 1

# `NLS_DATE_FORMAT`, e a razao de ele estar aqui em vez de nos dados.
#
# A primeira execucao desta carga falhou com ORA-01861, "literal does not
# match format string", na linha
#
#     INSERT INTO transacao (...) VALUES (1, 1, 2, 150.00, '2026-01-10')
#
# A leitura facil seria "o Oracle nao aceita data em ISO, e preciso reescrever
# os literais". E ela esta ERRADA, e levaria a mexer nos dados de 10 linhas de
# transacao para resolver um problema que nao esta neles.
#
# O que o Oracle faz e converter string para DATE usando o
# **NLS_DATE_FORMAT da sessao**, que por padrao e `DD-MON-RR` -- um formato
# com mes abreviado em texto, dependente do idioma. `'2026-01-10'` nao casa
# com ele.
#
# Entao a correcao e UMA LINHA na sessao, e os dados ficam intactos. E a
# diferenca entre as duas correcoes e o assunto: uma mexe em 10 literais de
# data e esconde que o motor e configuravel; a outra declara a configuracao.
#
# Os outros tres motores aceitam `'2026-01-10'` sem configurar nada, e nisso
# sao mais convenientes -- mas tambem sao os tres que nao deixam a politica de
# conversao explicita em lugar nenhum.
{
    echo 'SET FEEDBACK OFF'
    echo 'WHENEVER SQLERROR EXIT SQL.SQLCODE'
    echo "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';"
    cat "$CARGA"
    echo 'EXIT'
} | sql_qlab || exit 1

# A procedure. `WHENEVER SQLERROR` não pega erro de COMPILAÇÃO de PL/SQL: o
# `CREATE PROCEDURE` "tem sucesso" com a procedure inválida, e o erro só
# aparece em `USER_ERRORS`. Então a compilação é verificada explicitamente
# depois -- sem isso, uma procedure que não compila daria "0 passaram" com
# mensagem sobre a regra de negócio.
{
    echo 'SET FEEDBACK OFF'
    cat "$AQUI/transferir.sql"
    echo 'EXIT'
} | sql_qlab || exit 1

erros=$({
    echo 'SET HEADING OFF'
    echo 'SET FEEDBACK OFF'
    echo 'SET PAGESIZE 0'
    echo "SELECT line || ': ' || text FROM user_errors WHERE name = 'TRANSFERIR';"
    echo 'EXIT'
} | sql_qlab 2>&1 | grep -v '^$')

if [ -n "$erros" ]; then
    echo 'a procedure PL/SQL NÃO compilou:' >&2
    printf '%s\n' "$erros" | sed 's/^/    /' >&2
    exit 1
fi

# A mesma configuracao de data na sessao dos testes: o caso 10 insere uma
# linha em `pessoa`, e uma futura insercao em `transacao` dentro de um teste
# falharia pelo mesmo ORA-01861 -- com mensagem sobre formato, num teste sobre
# regra de negocio.
{
    echo "ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';"
    cat "$AQUI/testa.sql"
} | sql_qlab
