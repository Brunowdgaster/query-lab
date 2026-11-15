# query-lab — a mesma pergunta, oito linguagens, três modelos de dados

Um domínio (grafo social + transações), uma pergunta, e implementações em
**SQL ANSI, PL/pgSQL, PL/SQL, T-SQL, Cypher, SPARQL, GraphQL e Python** — que
têm de dar **a mesma resposta**, verificada por script.

> **Status:** 3 das 8 linguagens feitas e verificadas, com **12 testes**.
> Python, SQL ANSI e PL/pgSQL estão completos. Ver [Roadmap](#roadmap).

A tese não é "sei oito dialetos". É que **modelo de dados é uma escolha com
consequências**, e a única forma honesta de mostrar isso é fazer a mesma
pergunta a cada um e medir o que cada um cobra.

## A pergunta que separa os modelos

> *Quem está a até 3 saltos de amizade de Ana?*

```
   Ana(1) --- Bruno(2) --- Diego(4) --- Fabio(6) --- Gabi(7) --- Hugo(8) --- Iris(9)
     |                                     |
   Carla(3) --- Elisa(5) ------------------/

   Joao(10) --- Kelly(11) --- Lucas(12)     <- componente SEPARADO
```

Resposta: **Bruno e Carla** (1 salto), **Diego e Elisa** (2), **Fabio** (3).

| linguagem | como se expressa | custo |
|---|---|---|
| **Cypher** | `-[:AMIGO*1..3]-` | uma expressão |
| **SPARQL** | *property path* com `{1,3}` | uma expressão |
| **SQL** | CTE recursivo | espelhar aresta + controlar ciclo + contar saltos à mão |
| **GraphQL** | **não se expressa** | o tipo não tem recursão; o resolver é que resolve |
| **Python** | BFS | dez linhas, e nenhuma mágica |

### O limite de 3 não é decoração

Ele **corta no meio do grafo**: Gabi está a 4 saltos e tem de ficar de fora.
Um limite que abrangesse o componente inteiro não testaria a contagem de
saltos, e um *off-by-one* passaria. O componente de Joao/Kelly/Lucas existe
pelo mesmo motivo: ele testa que a travessia para onde o grafo acaba.

## O que já está feito

### `python/referencia.py` — a resposta em que se pode confiar

As outras sete implementações são conferidas contra esta, e Python foi
escolhido por ser o mais simples: BFS explícito, sem otimizador, sem
planejador, sem índice. Se estiver errado, está errado de um jeito que se vê.

É a mesma estratégia do resto do portfólio: no `p01-metal-vm` o bytecode é
montado pela implementação em C e executado pelos sete portes; no
`p02-forge-lang` os 23 casos saem do compilador em Haskell e são conferidos
pelos portes em OCaml e F#. **A referência é sempre a implementação mais
simples, nunca a mais rápida.**

### `sql/` — SQL ANSI, e o mesmo arquivo em dois motores

`esquema.sql`, `carga.sql`, `alcance.sql` e `saldo.sql` rodam **sem uma linha
de diferença** em SQLite 3.46 e PostgreSQL 18.6, e a suíte verifica que os
dois dão a mesma resposta. Isso é o que torna a comparação com Cypher e SPARQL
honesta: a diferença medida é de **modelo**, não de fornecedor.

O preço do ANSI está documentado em cada arquivo. O mais visível é o controle
de ciclo, que compara o caminho percorrido como **texto**:

```sql
AND a.caminho NOT LIKE '%,' || CAST(e.destino AS VARCHAR(10)) || ',%'
```

O PostgreSQL tem `ARRAY` e `= ANY`, que seriam limpos; o SQLite não tem. E os
delimitadores em volta de cada id não são decoração — sem eles, procurar o id
`1` casaria dentro de `12` e o filtro cortaria caminhos válidos em silêncio.

### `plpgsql/` — a procedure, e a atomicidade

`transferir(de, para, valor)` grava uma transação se as pessoas existirem, não
forem a mesma, o valor for positivo e o saldo cobrir.

O teste que importa não é "a transferência funciona". É **que depois de uma
falha nada ficou gravado**: uma procedure que valida, grava e só então estoura
deixa o banco inconsistente, e nenhum teste de caminho feliz pegaria isso.

E ela **não dá COMMIT**, de propósito: deixa a transação com o chamador, para
que várias transferências possam ser atômicas em conjunto. É a decisão oposta
à que o PL/SQL toma por hábito, e a comparação entre os três dialetos vai em
`docs/COMPARACAO.md` quando os outros dois estiverem feitos.

## Os quatro códigos de erro que eu escolhi errado

A primeira versão da procedure usava `P0001` a `P0004`, com um comentário meu
afirmando que a classe `P0` é reservada ao usuário.

**É falso.** Os quatro colidem com códigos do próprio PostgreSQL:

| meu uso | código | o que é de verdade |
|---|---|---|
| pessoa não encontrada | `P0001` | `raise_exception` — o genérico de todo `RAISE` sem código |
| saldo insuficiente | `P0002` | `no_data_found` |
| valor inválido | `P0003` | `too_many_rows` |
| auto-transferência | `P0004` | **`assert_failure`** |

A colisão com `P0004` deu o sintoma alto: **`EXCEPTION WHEN OTHERS` se recusa
a capturar `assert_failure`** — é documentado, junto com `query_canceled`, e
foi medido aqui: nem um `WHEN OTHERS` externo pegou. O erro de
auto-transferência era, por construção, **intratável**.

As outras três são piores porque são silenciosas. `P0002` significaria que
"saldo insuficiente" é indistinguível de um `SELECT INTO STRICT` que não achou
linha — e a procedure usa exatamente isso duas vezes. Um chamador que reagisse
a `P0002` recarregando saldo reagiria também a um bug de linha faltando.

E o detalhe que faz disso o melhor achado do projeto até agora:

> **Os testes passavam em três das quatro colisões**, porque o teste conferia o
> mesmo código errado que a procedure levantava. Dois lados concordando não é
> verificação quando os dois saem da mesma premissa falsa.

A correção é a classe `QL`: a ISO reserva as classes que começam com `5`-`9`
ou `I`-`Z` para o implementador, e o PostgreSQL não usa nenhuma. Que `QL004`
**é** capturável por `WHEN OTHERS` foi medido, não suposto — e a suíte agora
tem um teste que falha se algum `P0***` voltar.

## O teste pegou um erro meu de aritmética

O caso 7 esperava saldo 899,50 e o banco deu 839,50.

O banco estava certo: a transação 10 é `de=2, para=1`, então os 30,00 são
**saída** de Bruno, não entrada. Errar o sinal custa o dobro do valor — os
60,00 exatos da diferença. A verificação cruzada serve justamente para quando
a **expectativa** está errada, e não o código.

## Duas fricções do PL/pgSQL que valem registrar

**`INOUT` exige argumento gravável, mas só às vezes.** De dentro de um bloco
PL/pgSQL, `CALL transferir(..., NULL)` falha com *"is an output parameter but
corresponding argument is not writable"* — e o **mesmo** `CALL` funciona
quando vem direto do `psql`, onde o `NULL` literal é aceito. O comando é
válido num contexto e inválido no outro, e a diferença não está na procedure.

**`SELECT INTO` sem `STRICT` não falha quando não acha.** Ele deixa a variável
`NULL` e **segue em frente**, e a falha aparece muito depois, como violação de
`NOT NULL` no `INSERT`, com mensagem que não menciona o nome errado.

## Rodando

```bash
sudo apt-get install -y sqlite3 postgresql postgresql-client
sudo service postgresql start
./verifica.sh
```

A suíte **pula** o que não está instalado em vez de falhar: o projeto depende
de bancos que não cabem todos em qualquer máquina, e uma suíte que falha por
ausência de Oracle não distingue "quebrou" de "não tem".

```
  ok    alcance a 3 saltos acha 5 pessoas
  ok    Gabi (4 saltos) fica fora do limite de 3
  ok    o MESMO .sql dá a MESMA resposta no PostgreSQL
  ok    os 8 testes da procedure passam
  ok    nenhum ERRCODE da classe P0 (colidiria com os do PostgreSQL)
  12 passaram, 0 falharam
```

## Roadmap

| linguagem | o que vai mostrar | situação |
|---|---|---|
| **Python** | a referência, e o BFS que não tem mágica | ✅ feito |
| **SQL ANSI** | CTE recursivo, e o preço de não ter travessia | ✅ feito |
| **PL/pgSQL** | atomicidade, `ERRCODE`, e transação do chamador | ✅ feito |
| **Cypher** | travessia como primitiva da linguagem | a fazer |
| **SPARQL** | *property path*, e a inferência que nenhum dos outros faz | a fazer |
| **GraphQL** | **o que o modelo não consegue expressar** | a fazer |
| **T-SQL** | `TRY...CATCH`, `XACT_ABORT`, e `THROW` vs `RAISERROR` | a fazer — exige SQL Server em contêiner |
| **PL/SQL** | `PRAGMA AUTONOMOUS_TRANSACTION` e `RAISE_APPLICATION_ERROR` | a fazer — exige Oracle em contêiner |

Os dois últimos são os caros: SQL Server e Oracle rodam de graça em edição de
desenvolvedor, mas são imagens de 1,5 GB e 2,5 GB. Eles entram por último, e
a suíte já está preparada para pulá-los.

## Licença

MIT, em `LICENSE`.
