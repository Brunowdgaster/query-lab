#!/usr/bin/env python3
"""traduz_carga.py — converte sql/carga.sql para a forma que o Oracle aceita.

## Por que este arquivo existe

`sql/carga.sql` usa `VALUES` com varias linhas:

    INSERT INTO pessoa (id, nome, cidade, saldo_inicial) VALUES
      (1,'Ana','Recife',1000.00), (2,'Bruno','Recife',1000.00), ...

Isso esta no SQL-92, e funciona em SQLite, PostgreSQL e SQL Server -- os tres
motores onde o arquivo ja roda sem alteracao.

**O Oracle nao aceita.** Ele exige um `INSERT` por linha, ou a forma
`INSERT ALL ... SELECT * FROM DUAL`. E a divergencia de dialeto mais basica
que apareceu neste projeto, e ela esta num recurso do padrao com 30 anos.

## Por que traduzir, e nao escrever um segundo arquivo de carga

Escrever `plsql/carga.sql` a mao criaria DUAS fontes para os mesmos dados, e
este projeto ja pagou por isso: `saldo_inicial` foi acrescentado ao esquema e
esquecido no CSV, e tres implementacoes rodaram com um dominio diferente das
outras sem que nada acusasse. O sintoma apareceu por acidente, e o
`python/confere_carga.py` existe por causa disso.

Entao a carga do Oracle e DERIVADA da mesma fonte, em tempo de execucao. Se
`sql/carga.sql` mudar, esta tambem muda -- nao ha o que esquecer de
sincronizar.

## O que a traducao faz, e o que ela NAO faz

Apenas quebra o `VALUES` multi-linha em um `INSERT` por tupla. Nao reescreve
tipos, nao traduz funcoes, nao toca nos valores. Se fosse preciso mais que
isso, a afirmacao "o esquema e o mesmo" deixaria de ser verdadeira e o lugar
de dizer isso seria o README, nao um script silencioso.
"""
import re
import sys
from pathlib import Path

AQUI = Path(__file__).resolve().parent
FONTE = AQUI.parent / 'sql' / 'carga.sql'


def tuplas(corpo: str):
    """Separa `(a,b),(c,d)` em ['(a,b)', '(c,d)'].

    Feito a mao e nao com `split(',')` porque ha virgulas DENTRO das tuplas.
    O contador de parenteses e o minimo que resolve, e a varredura respeita
    aspas simples para o caso de um valor conter um parentese.
    """
    fora = []
    nivel = 0
    atual = []
    em_texto = False
    for ch in corpo:
        if em_texto:
            atual.append(ch)
            if ch == "'":
                em_texto = False
            continue
        if ch == "'":
            em_texto = True
            atual.append(ch)
            continue
        if ch == '(':
            nivel += 1
            if nivel == 1:
                atual = []
                continue
        if ch == ')':
            nivel -= 1
            if nivel == 0:
                fora.append(''.join(atual).strip())
                continue
        if nivel >= 1:
            atual.append(ch)
    return fora


def main() -> int:
    if not FONTE.exists():
        print(f'nao achei {FONTE}', file=sys.stderr)
        return 1

    texto = FONTE.read_text(encoding='utf-8')

    # Remove os comentarios de linha ANTES de procurar os INSERT.
    #
    # Isto nao e zelo: e a falha que mais se repetiu neste portfolio -- onze
    # vezes -- um teste ou uma varredura sobre CODIGO que tambem le a PROSA.
    # Um `INSERT` citado dentro de um comentario explicativo viraria carga
    # real, e o erro apareceria como dado a mais no banco, nao como erro de
    # sintaxe.
    sem_comentario = re.sub(r'--[^\n]*', '', texto)

    saida = []
    achou = 0
    for m in re.finditer(
        r'INSERT\s+INTO\s+(\w+)\s*\(([^)]*)\)\s*VALUES\s*(.*?);',
        sem_comentario, re.S | re.I,
    ):
        tabela, colunas, corpo = m.group(1), m.group(2), m.group(3)
        achou += 1
        for t in tuplas(corpo):
            saida.append(
                f'INSERT INTO {tabela} ({colunas.strip()}) VALUES ({t});')

    if achou == 0:
        print('nenhum INSERT encontrado em sql/carga.sql', file=sys.stderr)
        return 1

    # O COMMIT e explicito porque no Oracle o padrao do sqlplus NAO commita ao
    # sair quando a sessao termina por erro -- e uma carga pela metade daria
    # um teste que falha por dado faltando, com mensagem sobre a regra de
    # negocio.
    print('\n'.join(saida))
    print('COMMIT;')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
