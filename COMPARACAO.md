# A mesma procedure, em três dialetos procedurais

`plpgsql/transferir.sql`, `tsql/transferir.sql` e `plsql/transferir.sql`
implementam **a mesma regra de negócio**, deliberadamente simples:

> `transferir(de, para, valor)` grava uma transação, desde que as duas pessoas
> existam, não sejam a mesma, o valor seja positivo, e o saldo de quem envia
> cubra o valor.

Os três passam pelos **mesmos sete casos de teste**. O que este documento
compara é o que cada fornecedor cobra para chegar lá — e cada afirmação abaixo
foi **medida**, nos casos 8 a 11 de cada suíte, e não lida na documentação.

A razão de medir em vez de citar: este portfólio já publicou quatro
afirmações falsas sobre motores de banco, e três delas **passaram nos
testes**, porque o teste conferia o mesmo código errado que o código
levantava.

---

## 1. Como cada um identifica um erro de negócio

| | formato | faixa do usuário | colisão possível? |
|---|---|---|---|
| **PL/pgSQL** | `SQLSTATE`, 5 caracteres ISO | classes `5`–`9` e `I`–`Z` | **sim, e aconteceu** |
| **T-SQL** | inteiro | `>= 50000` | não, por construção |
| **PL/SQL** | inteiro negativo | `-20000` a `-20999` (mil) | não, por construção |

O mapeamento, que um chamador falando com os três precisa ter:

| significado | PL/pgSQL | T-SQL | PL/SQL |
|---|---|---|---|
| pessoa não encontrada | `QL001` | `50001` | `-20001` |
| saldo insuficiente | `QL002` | `50002` | `-20002` |
| valor não positivo | `QL003` | `50003` | `-20003` |
| origem = destino | `QL004` | `50004` | `-20004` |

### E aqui o PostgreSQL é o pior dos três

A primeira versão do PL/pgSQL usava `P0001`–`P0004`, com um comentário meu
afirmando que a classe `P0` era reservada ao usuário. **Era falso**, e os
quatro códigos colidiam com códigos do próprio PostgreSQL — `raise_exception`,
`no_data_found`, `too_many_rows`, `assert_failure`.

A colisão com `P0004` tinha sintoma alto: **`EXCEPTION WHEN OTHERS` recusa-se
a capturar `assert_failure`**. O erro de auto-transferência era, por
construção, intratável.

As outras três eram piores por serem silenciosas, e **três dos quatro testes
passavam**, porque conferiam o mesmo código errado que a procedure levantava.
Dois lados concordando não é verificação quando os dois saem da mesma premissa
falsa.

O T-SQL e o PL/SQL tornam isso **impossível**, com uma fronteira numérica em
vez de uma convenção de classes. É o ponto mais claro a favor dos dois
comerciais neste documento.

A contrapartida do Oracle: **mil códigos é pouco.** E a fronteira é dura —
`RAISE_APPLICATION_ERROR(-19999, ...)` estoura `ORA-21000` em vez de aceitar
um código "incomum". Medido no caso 9.

---

## 2. Lançar o erro: número *e* mensagem formatada

| | uma chamada dá os dois? |
|---|---|
| **PL/pgSQL** | **sim** — `RAISE EXCEPTION 'valor: %', v USING ERRCODE = 'QL003'` |
| **PL/SQL** | **sim** — `RAISE_APPLICATION_ERROR(-20003, 'valor: ' \|\| v)` |
| **T-SQL** | **não** |

O T-SQL obriga a escolher, e isso foi medido no caso 10 da suíte dele:

```
THROW 50002, 'mensagem pronta', 1        -> ERROR_NUMBER() = 50002
RAISERROR('saldo: %s tem %s', 16, 1, ...) -> ERROR_NUMBER() = 50000
```

`RAISERROR` **formatou a mensagem corretamente** e **achatou o número**. Ter
os dois exigiria registrar a mensagem em `sys.messages` com `sp_addmessage`,
que pede privilégio de servidor e deixa o código dependente do estado da
instalação.

O contorno é montar a mensagem numa variável e usar `THROW` — e é por isso que
cada erro no arquivo T-SQL tem **duas linhas onde os outros dois têm uma**.

---

## 3. `SELECT` numa variável: o que acontece quando não acha

Esta é a divergência mais perigosa dos três, porque as consequências são
silenciosas.

| | sem linha | com várias linhas |
|---|---|---|
| **PL/SQL** | **estoura sozinho** (`NO_DATA_FOUND`) | **estoura sozinho** (`TOO_MANY_ROWS`) |
| **PL/pgSQL** | silencioso: variável fica `NULL` — estoura só com `STRICT` | silencioso sem `STRICT` |
| **T-SQL** | **silencioso, e a variável fica com o VALOR ANTERIOR** | silencioso: sobra a última linha, em ordem não garantida |

O T-SQL é o pior caso, e foi medido: uma variável valendo `-999` antes de um
`SELECT` que não acha nada **continua valendo `-999` depois**. Não vira `NULL`.
Um código que reutilize a variável segue com o **id errado**, e não com nulo —
e nulo é o que qualquer leitor assume.

O Oracle é o melhor, e **não há como pedir o comportamento silencioso**.

### O custo em linhas de código

Buscar uma pessoa e tratar os dois casos:

| | linhas |
|---|---|
| **PL/SQL** | 3 (`SELECT INTO`, e um `EXCEPTION` que só **traduz** o erro) |
| **PL/pgSQL** | 6 (`INTO STRICT` mais o bloco `EXCEPTION`) |
| **T-SQL** | 8 (um `IF NOT EXISTS` e um `COUNT(*) > 1` por pessoa, à mão) |

**O mais estrito é o mais curto.** No Oracle o bloco `EXCEPTION` não é o que
torna a verificação possível — ela já aconteceu; ele apenas renomeia o erro
para o código do domínio.

### E um detalhe que só aparece medindo

`NO_DATA_FOUND` é ORA-**01403**, e todo outro código do Oracle em `SQLCODE` é
o negativo do número ORA. Esperei `-1403`.

**O medido foi `+100`.** É a única exceção que o Oracle alinhou ao padrão
ISO/ANSI, onde "nenhuma linha" é a condição `+100`. Foi o único caso desta
suíte que falhou na primeira execução, e a falha estava na minha expectativa.

---

## 4. A transação: quem manda, e o que pode destruí-la

As três procedures tomam a **mesma decisão** — não dar `COMMIT`, deixar a
transação com o chamador, para que várias transferências possam ser atômicas
em conjunto. As razões para a decisão, porém, são diferentes.

### PL/pgSQL: uma distinção que não se vê no código

* uma **FUNCTION** roda sempre dentro da transação do chamador e **não pode**
  dar `COMMIT` nem `ROLLBACK`;
* uma **PROCEDURE** (PostgreSQL 11+), chamada com `CALL` fora de transação
  explícita, **pode**.

A escolha de ser uma PROCEDURE é o que torna a decisão uma decisão.

### T-SQL: a procedure *poderia* destruir a transação de quem a chama

Medido no caso 9, e é o achado mais forte deste documento:

> `BEGIN TRAN` dentro de outra transação **não cria transação aninhada**:
> apenas incrementa `@@TRANCOUNT`. E **um** `ROLLBACK` desfaz **todos** os
> níveis.

A medição: `@@TRANCOUNT` interno igual a 2; depois de um único `ROLLBACK`,
igual a 0; e **a linha inserida pelo nível de fora desapareceu junto**.

Ou seja: se a procedure abrisse `BEGIN TRAN` e desse `ROLLBACK` ao ver saldo
insuficiente, destruiria a transação do chamador com tudo que ele já tinha
feito — **sem aviso, e sem o chamador poder se defender**.

É por isso que a versão T-SQL não abre transação nenhuma: ela valida tudo
antes de escrever, e escreve **uma única linha**, cuja atomicidade é a do
próprio comando. `SAVE TRANSACTION` seria o contorno, e tem porém próprio:
não funciona com a transação em estado não-commitável (`XACT_STATE() = -1`).

O caso 11 verifica a consequência: depois de a procedure estourar dentro de
uma transação do chamador, `@@TRANCOUNT` continua 1 e `XACT_STATE()` é 1
(commitável).

### PL/SQL: o hábito que o arquivo recusa, e o DDL que ninguém espera

Uma procedure PL/SQL **pode** dar `COMMIT`, e por hábito histórico muitas dão.
Esta não dá. `PRAGMA AUTONOMOUS_TRANSACTION` daria a ela uma transação
própria — errado aqui, e é o jeito certo de gravar auditoria que deva
sobreviver ao rollback da operação auditada.

E há um comportamento do Oracle **sem equivalente nos outros dois**, medido no
caso 10:

> **Todo DDL faz `COMMIT` implícito**, e leva o DML pendente com ele.

A medição: uma linha inserida sem `COMMIT`, um `CREATE TABLE` qualquer, e
então `ROLLBACK` — **a linha sobreviveu**. Não é opcional, não é configurável,
e não há aviso.

---

## 5. Devolver valor ao chamador

| | como | exige variável no chamador? |
|---|---|---|
| **PL/pgSQL** | parâmetro `INOUT` | **depende do contexto** |
| **T-SQL** | `OUTPUT` | sempre |
| **PL/SQL** | `OUT` | sempre |

A assimetria do PostgreSQL é real e foi encontrada ao escrever o teste:
`CALL transferir(..., NULL)` **é aceito** direto do `psql` e **recusado** de
dentro de um bloco PL/pgSQL, com *"is an output parameter but corresponding
argument is not writable"*.

O mesmo comando é válido num contexto e inválido no outro, e a diferença não
está na procedure.

---

## 6. Dois recursos que não existem nos três

### `%TYPE`: o tipo vem da coluna

`v_saldo pessoa.saldo_inicial%TYPE` declara a variável com o tipo da **coluna**.
Se a coluna virar `DECIMAL(14,4)`, a variável acompanha sem que ninguém edite
o arquivo.

**PL/SQL e PL/pgSQL têm. T-SQL não.** Lá o tipo é repetido à mão, e uma
mudança de escala na coluna deixa a variável truncando em silêncio.

### `PRAGMA EXCEPTION_INIT`: o chamador trata por nome

Só o Oracle tem, e foi medido no caso 11:

```sql
saldo_insuficiente EXCEPTION;
PRAGMA EXCEPTION_INIT(saldo_insuficiente, -20002);
...
EXCEPTION WHEN saldo_insuficiente THEN ...
```

O número continua sendo o contrato, mas aparece **uma vez**, na declaração, em
vez de em cada ponto de tratamento. Nos outros dois, o chamador compara
`SQLSTATE` ou `ERROR_NUMBER()` com um literal, em todo lugar.

---

## 7. Onde o corpo da procedure é compilado

| | o corpo é compilado… | consequência |
|---|---|---|
| **PL/pgSQL** | **na execução** | erro de sintaxe no corpo passa pelo `CREATE PROCEDURE` |
| **T-SQL** | na criação | mas o **lote inteiro** compila antes de executar |
| **PL/SQL** | na criação | o `CREATE` "tem sucesso" com a procedure **inválida** |

As três têm armadilha, e as três apareceram ao escrever estes arquivos.

**PL/pgSQL**: o corpo é uma *string* (dollar quoting), então até rodar é texto
opaco.

**T-SQL**: uma subconsulta dentro de um `PRINT` (erro 1046) **num galho que só
executa em caso de falha** derrubou os 11 casos de uma vez — o lote não
compila, e nenhuma linha dele roda.

**PL/SQL**: o `CREATE PROCEDURE` de uma procedure com erro **retorna sucesso**;
o erro fica em `USER_ERRORS`, e só aparece quando alguém a chama. O
`plsql/roda.sh` consulta essa tabela explicitamente — sem isso, uma procedure
que não compila daria "0 passaram" com mensagem sobre regra de negócio.

---

## 8. E o que o SQL ANSI conseguiu

`sql/esquema.sql` afirma, no próprio cabeçalho, rodar **sem alteração** em
mais de um motor. O escopo cresceu durante este projeto, e a afirmação
aguentou:

| | SQLite | PostgreSQL | SQL Server | Oracle |
|---|---|---|---|---|
| `sql/esquema.sql` | ✅ | ✅ | ✅ | ✅ |
| `sql/carga.sql` | ✅ | ✅ | ✅ | ❌ |

**Quatro motores, um arquivo de esquema, zero linhas de dialeto.** Tipos,
`CHECK`, chaves estrangeiras compostas e índices — tudo no padrão, tudo aceito.

A carga é que não atravessa, por dois motivos, e os dois valem registrar:

1. **`VALUES` com várias linhas** — está no SQL-92, funciona nos outros três,
   e o Oracle **não aceita**. É a divergência mais básica encontrada neste
   projeto, num recurso do padrão com mais de trinta anos.

2. **O literal de data** `'2026-01-10'` deu `ORA-01861`. A leitura fácil seria
   "o Oracle não aceita data em ISO" — e está **errada**. O Oracle converte
   string para `DATE` usando o `NLS_DATE_FORMAT` da **sessão**, cujo padrão é
   `DD-MON-RR`. Uma linha de `ALTER SESSION` resolve, e os dados ficam
   intactos.

   A diferença entre as duas correções é o assunto: uma mexeria em dez
   literais de data e esconderia que o motor é configurável; a outra declara a
   configuração. Os outros três aceitam o literal sem configurar nada — e são
   também os três que não deixam a política de conversão explícita em lugar
   nenhum.

O `plsql/traduz_carga.py` faz a transformação (1) a partir de
`sql/carga.sql`, em vez de um segundo arquivo de carga escrito à mão. O motivo
é específico: este projeto **já** teve duas fontes para o mesmo domínio
divergirem — `saldo_inicial` foi acrescentado ao esquema e esquecido no CSV, e
três implementações rodaram com um domínio diferente das outras sem que nada
acusasse. O sintoma apareceu por acidente, e o `python/confere_carga.py`
existe por causa disso.

---

## 9. Resumo: quem ganha em quê

| critério | melhor | pior |
|---|---|---|
| código de erro sem colisão | T-SQL / PL/SQL (fronteira numérica) | **PL/pgSQL** (convenção, e eu errei) |
| número + mensagem numa chamada | PL/pgSQL / PL/SQL | **T-SQL** |
| rigor ao buscar uma linha | **PL/SQL** (automático) | **T-SQL** (silencioso, e deixa lixo) |
| verbosidade para fazer o certo | **PL/SQL** (3 linhas) | **T-SQL** (8 linhas) |
| não poder sabotar o chamador | PL/pgSQL / PL/SQL | **T-SQL** (`ROLLBACK` global) |
| tipo ancorado na coluna | PL/pgSQL / PL/SQL (`%TYPE`) | **T-SQL** (não tem) |
| tratar erro por nome | **PL/SQL** (`EXCEPTION_INIT`) | os outros dois |
| erro de sintaxe pego cedo | T-SQL / PL/SQL | **PL/pgSQL** (corpo é string) |
| quantidade de códigos de erro | PL/pgSQL / T-SQL | **PL/SQL** (mil, e fronteira dura) |
| aceitar o SQL-92 na carga | os outros três | **Oracle** (sem `VALUES` multilinha) |

Nenhum dos três ganha em tudo, e a conclusão útil não é um ranking: é que
**cada um exige um cuidado diferente para escrever a mesma regra de negócio
corretamente** — e que esse cuidado não está no SQL, está no dialeto.
