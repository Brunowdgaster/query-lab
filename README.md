# query-lab — a mesma pergunta, oito linguagens, três modelos de dados

Um domínio (grafo social + transações), uma pergunta, e implementações em
**SQL ANSI, PL/pgSQL, PL/SQL, T-SQL, Cypher, SPARQL, GraphQL e Python** — que
têm de dar **a mesma resposta**, verificada por script.

> **Status: as 8 linguagens feitas e verificadas**, com **28 testes**.
> A comparação entre os três dialetos procedurais está em
> **[COMPARACAO.md](COMPARACAO.md)**.
>
> O T-SQL e o PL/SQL exigem contêineres, e os tamanhos aqui são **medidos**:
> SQL Server **2,21 GB**, Oracle **13,8 GB**. **O CI roda os dois**, o Oracle
> num job separado.
>
> Eu havia escrito que o PL/SQL ficaria fora do CI porque 13,8 GB *"não cabem
> nos ~14 GB do runner"*. Acrescentei um passo que mede o disco para dar
> evidência a isso, e ele mediu **91 GB livres** — refutando a afirmação que
> fui buscar nele. A medição que eu criei para me confirmar me corrigiu, e
> está em [Por que o PL/SQL tem job próprio](#por-que-o-plsql-tem-job-próprio).

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
| **SQL** | CTE recursivo | espelhar aresta + controlar ciclo + contar saltos à mão |
| **SPARQL** | **união de três caminhos fixos** | o padrão **não tem** repetição limitada — ver abaixo |
| **GraphQL** | **não se expressa** | o tipo não tem recursão; o resolver é que resolve |
| **Python** | BFS | dez linhas, e nenhuma mágica |

Todas as seis implementações dão **a mesma resposta**, e a suíte compara byte
a byte contra `dados/esperado/alcance.json`.

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

### `sql/` — SQL ANSI, e o mesmo arquivo em QUATRO motores

`esquema.sql`, `carga.sql`, `alcance.sql` e `saldo.sql` rodam **sem uma linha
de diferença** em SQLite 3.46 e PostgreSQL 18.6, e a suíte verifica que os
dois dão a mesma resposta.

**E o escopo cresceu.** Com o T-SQL e o PL/SQL prontos, o esquema foi testado
em dois motores a mais:

| | SQLite | PostgreSQL | SQL Server | Oracle |
|---|---|---|---|---|
| `sql/esquema.sql` | ✅ | ✅ | ✅ | ✅ |
| `sql/carga.sql` | ✅ | ✅ | ✅ | ❌ |

Quatro motores, um arquivo de esquema, **zero linhas de dialeto** — tipos,
`CHECK`, chaves estrangeiras e índices, tudo no padrão e tudo aceito.

A carga é que não atravessa, e por um motivo que surpreende: **`VALUES` com
várias linhas está no SQL-92 e o Oracle não aceita.** É a divergência mais
básica encontrada neste projeto, num recurso do padrão com mais de trinta anos.
O `plsql/traduz_carga.py` deriva a forma do Oracle **da mesma fonte**, em vez
de haver um segundo arquivo de carga — porque duas fontes para o mesmo domínio
já divergiram aqui uma vez, e o
[teste que nasceu disso](#as-duas-fontes-do-domínio-derivaram-e-agora-há-um-teste)
é o que conta a história. Isso é o que torna a comparação com Cypher e SPARQL
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

### `cypher/` — travessia como primitiva

```cypher
MATCH caminho = (origem:Pessoa {nome: 'Ana'})-[:AMIGO*1..3]-(p:Pessoa)
WHERE p.nome <> 'Ana'
RETURN p.nome AS nome, min(length(caminho)) AS saltos
ORDER BY saltos, nome;
```

As três coisas que o SQL faz à mão e aqui não existem: `-[:AMIGO]-` sem seta
**já atravessa os dois sentidos**; Cypher **não repete relacionamento** dentro
de um caminho, então não há controle de ciclo; e `length(caminho)` sai do
próprio caminho.

O que o Cypher **não** resolve de graça: a travessia devolve um caminho por
rota, não um nó por pessoa, então o `min(...)` é tão necessário quanto em SQL.
Dizer isso é o que separa comparação de propaganda.

O motor é o **Kuzu** — embarcado como o SQLite, licença MIT, sem servidor nem
JVM. Duas divergências reais com o Cypher do Neo4j estão documentadas:
`SHORTEST 1` **compila e devolve zero linhas**, e a compreensão de lista
`[n IN nodes(c) | n.nome]` não é aceita (`Variable n is not in scope`).

### `sparql/` — e a correção de uma afirmação minha

A primeira versão deste README dizia que o SPARQL responde a pergunta com
`:conhece{1,3}`. **Está errado.** O quantificador `{n,m}` existiu num
*rascunho* do SPARQL 1.1 e **foi removido da recomendação final**:

```
:conhece+        aceito      fecho transitivo ILIMITADO
:conhece{1,3}    ParseException: Expected SelectQuery
```

Então o SPARQL tem a travessia que o SQL só alcança com CTE recursivo, e **não
tem** a que o Cypher escreve como `*1..3`. Cada modelo ganha e perde num eixo
diferente:

| pergunta | SQL | Cypher | SPARQL |
|---|---|---|---|
| alcançável a **qualquer** distância | caro | fácil | **fácil** |
| alcançável em **até N** saltos | caro | **fácil** | caro |

A pergunta foi escolhida bem o bastante para expor isso, e a suíte tem um
teste que **falha se um motor futuro aceitar `{1,3}`** — para o README não
ficar errado em silêncio.

O que o SPARQL tem de genuinamente seu é a direção invertida numa expressão:
`(:conhece|^:conhece)` — o `^` inverte, e é muito mais curto que o `UNION ALL`
espelhando a tabela em SQL.

### A inferência: o que nenhum dos outros dois modelos faz

Declarando **no vocabulário**, não nos dados:

```turtle
:conhece      a                   owl:SymmetricProperty .
:amigoIntimo  rdfs:subPropertyOf  :conhece .
```

E **um único fato** gravado só como `:amigoIntimo`, ligando os dois
componentes do grafo: `:p3 (Carla) :amigoIntimo :p10 (Joao)`.

```
Triplas: 102 declaradas -> 292 após a dedução

  antes da inferência:  Bruno, Carla, Diego, Elisa, Fabio
  depois:               Bruno, Carla, Diego, Elisa, Fabio, Joao, Kelly

  apareceram por DEDUÇÃO: Joao, Kelly
```

**A consulta não foi alterada**, e não sabe que `:amigoIntimo` existe. Em SQL
isso exigiria mudar a consulta ou criar uma `VIEW`; em Cypher, trocar
`-[:AMIGO]-` por `-[:AMIGO|AMIGO_INTIMO]-` em cada consulta que atravessa
amizade.

A honestidade da demonstração: `rdflib` **não** faz inferência sozinho — ela
vem do `owlrl`. Isso importa porque a dedução é capacidade do **modelo**
(RDF/OWL têm semântica definida para ela), não de uma biblioteca em
particular. Um motor relacional não tem onde colocar essa semântica; não é
questão de ninguém ter implementado.

E a primeira versão desta demonstração **não demonstrava nada**: o fato
deduzido estava entre Iris e Joao, a 6 saltos de Ana — longe demais para
entrar no limite de 3, e a resposta não mudava. A suíte agora exige que Joao e
Kelly apareçam.

### `graphql/` — o que o modelo não expressa

GraphQL é uma linguagem de **seleção** sobre um grafo de tipos, não de
**consulta** sobre um grafo de dados. Há três saídas, e as três estão
implementadas para que a afirmação seja verificável:

**Saída 1 — aninhar `amigos` três níveis à mão.** É o que os tutoriais
mostram. Medido:

```
  nós na resposta:        14
  pessoas distintas:      6
  a própria Ana voltou:   SIM
  caminhos com repetição: 6
  exemplo:                Ana -> Bruno -> Ana
```

A resposta correta tem **5 pessoas**. Esta árvore tem 14 nós e 6 nomes, **com
a origem entre eles** — porque nada no esquema impede o ciclo (`amigos:
[Pessoa!]!` é um tipo recursivo sem noção de caminho percorrido), e a resposta
é uma árvore com repetição, não um conjunto com distâncias. A profundidade
está **no texto da consulta**: "até 4 saltos" é outra consulta, não outro
argumento.

**Saída 2 — um campo que já é a resposta.** `alcance(de: "Ana", saltos: 3)`
acerta, e acerta porque **a travessia roda em Python** — o resolver chama o
mesmo BFS de `python/referencia.py`. O `saltos: 3` é um argumento que o
servidor interpreta; o `3` de `*1..3` em Cypher é parte da expressão avaliada
pelo motor. A diferença não é cosmética.

**Saída 3 — admitir que a pergunta é outra.** Mostrar só o lado em que GraphQL
perde seria escolher a prova. Numa única requisição, com o cliente escolhendo
o formato:

```
  Ana (Recife), saldo 834.75
  amigos: Bruno (Recife), Carla (Olinda)
  enviou:
      150.00 para Bruno
       45.25 para Carla
```

Três formas de dados — um escalar **calculado**, uma lista de pessoas, e uma
lista de transações com o destinatário embutido. Em SQL são três consultas, ou
uma com `JOIN` que devolve linhas repetidas e deixa remontar a hierarquia para
o cliente. E o `saldo` ser derivado é invisível ao cliente: no tipo, campo
calculado e campo armazenado são indistinguíveis.

## O menor caminho não é único, e isso mudou a verificação

A pergunta do caminho (*"qual o menor caminho de Ana até Gabi?"*) era
comparada contra uma resposta gravada, byte a byte — a mesma estratégia que
funciona para o alcance.

Medindo o Kuzu, as duas cláusulas de menor caminho deram respostas
**diferentes e as duas corretas**:

```
SHORTEST       Ana -> Bruno -> Diego -> Fabio -> Gabi    4 saltos
ALL SHORTEST   Ana -> Carla -> Elisa -> Fabio -> Gabi    4 saltos
```

Ana alcança Fabio pelos dois lados do ciclo, com o mesmo comprimento. Então
comparar o caminho literalmente testaria a **ordem interna** de cada motor e
reprovaria resposta certa.

`python/valida_caminho.py` verifica o que é bem definido: o número de saltos,
os extremos, que **cada par consecutivo é uma amizade real**, e que nenhum nó
se repete. Testado nos dois sentidos — aceita as implementações corretas e
recusa caminho com salto inventado, com contagem errada e com nó repetido,
cada um com a mensagem do defeito.

A pergunta do alcance **continua** com comparação literal, e deve: ali a
resposta é um conjunto com distâncias mínimas, que é único.

## As duas fontes do domínio derivaram, e agora há um teste

O domínio entra nos motores por dois caminhos: os **CSV** (que Python, Kuzu e
rdflib leem direto) e os `INSERT` literais de `sql/carga.sql` (que SQLite e
PostgreSQL usam). A duplicação é deliberada — `.import` e `COPY` são comandos
de *ferramenta*, não de linguagem, e divergem.

E as duas derivaram: `saldo_inicial` foi acrescentado ao esquema e ao
`carga.sql` e **esquecido no CSV**. Três implementações passaram a rodar com
um domínio diferente das outras, e **nada acusava** — o sintoma só apareceu
quando o Kuzu achou 3 campos onde o esquema prometia 4. Por acidente, não por
verificação.

`python/confere_carga.py` compara as duas fontes linha por linha e falha se
discordarem. Sem ele, manter as duas em sincronia era só boa intenção.

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

## Por que o PL/SQL tem job próprio

Porque a razão que eu dei primeiro era falsa, e o teste que escrevi para
provar que ela era verdadeira provou o contrário.

**O que eu afirmei:** que o PL/SQL não poderia rodar no CI, porque a imagem do
Oracle tem 13,8 GB e *"o runner do GitHub tem cerca de 14 GB de disco"*.

A primeira metade era medida — `docker images` diz 13,8 GB, e isso já havia
corrigido um registro meu anterior que dizia "~2,5 GB". **A segunda metade eu
afirmei de memória.**

Então criei no workflow um passo chamado *"o disco do runner, medido"*, com
este trecho dentro:

```bash
livre_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
echo "livre em /: ${livre_gb} GB   |   imagem do Oracle: 14 GB"
if [ "$livre_gb" -gt 20 ]; then
  echo "NOTA: ha espaco de sobra -- vale reavaliar a dispensa do PL/SQL"
fi
```

A intenção era deixar a dispensa com evidência no log em vez de apoiada numa
frase do README. E a primeira execução imprimiu:

```
livre em /: 91 GB   |   imagem do Oracle: 14 GB
NOTA: ha espaco de sobra -- vale reavaliar a dispensa do PL/SQL
```

**91 GB.** O aviso que eu havia escrito para o caso de eu estar errado
disparou na primeira vez que o código rodou.

### A razão verdadeira, que é mais fraca e por isso está escrita

O PL/SQL roda no CI. Num job separado, por dois motivos que **sobrevivem à
medição**:

* baixar 13,8 GB dentro do job das consultas atrasaria a verificação das
  outras sete linguagens, e faria uma **falha de rede aparecer como falha
  delas**;
* o banco leva ~78 s só para subir, porque cria o CDB.

Nenhum dos dois é "não cabe". São argumentos de **tempo e de isolamento de
falha**, e o job `plsql` imprime os dois tempos — o do `docker pull` e o da
suíte — justamente para que ninguém precise acreditar em mim sobre eles.

### E por que isto está no README em vez de corrigido em silêncio

Porque é a décima-segunda vez que este portfólio registra o mesmo padrão: **o
instrumento esconde — ou neste caso refuta — o próprio sinal.** As onze
anteriores estão em `poliglota/CONTEXTO.md`, seção 6.

A diferença desta é que o instrumento funcionou *perfeitamente*. Ele mediu o
que prometia medir, e o que ele mediu contradisse quem o escreveu. É o melhor
resultado possível para um teste, e o pior possível para a afirmação que ele
foi criado para apoiar.

## Rodando

```bash
# relacional
sudo apt-get install -y sqlite3 postgresql postgresql-client
sudo service postgresql start

# grafo, RDF e GraphQL -- embarcados, sem servidor
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt

./verifica.sh
```

As versões em `requirements.txt` são **fixas**, pelo mesmo argumento do
nixpkgs travado: "latest" não responde *"com o que isso foi verificado"*. E
aqui o risco é concreto — a suíte afirma que o SPARQL 1.1 recusa `{1,3}`, e um
rdflib futuro que aceitasse como extensão tornaria o README errado.

A suíte **pula** o que não está instalado em vez de falhar: o projeto depende
de bancos que não cabem todos em qualquer máquina, e uma suíte que falha por
ausência de Oracle não distingue "quebrou" de "não tem".

```
  ok    alcance a 3 saltos acha 5 pessoas
  ok    Gabi (4 saltos) fica fora do limite de 3
  ok    o MESMO .sql dá a MESMA resposta no PostgreSQL
  ok    os 8 testes da procedure passam
  ok    nenhum ERRCODE da classe P0 (colidiria com os do PostgreSQL)
  ok    dados/*.csv e sql/carga.sql declaram o mesmo dominio
  ok    Cypher da a MESMA resposta, byte a byte
  ok    Cypher: 4 saltos, caminho válido (Ana -> Bruno -> Diego -> Fabio -> Gabi)
  ok    SPARQL 1.1 recusa {1,3}, como o padrao manda
  ok    a inferencia traz Joao e Kelly por DEDUCAO
  ok    o aninhamento a mao traz a ORIGEM de volta (ciclo)
  22 passaram, 0 falharam
```

## Roadmap

| linguagem | o que vai mostrar | situação |
|---|---|---|
| **Python** | a referência, e o BFS que não tem mágica | ✅ feito |
| **SQL ANSI** | CTE recursivo, e o preço de não ter travessia | ✅ feito |
| **PL/pgSQL** | atomicidade, `ERRCODE`, e transação do chamador | ✅ feito |
| **Cypher** | travessia como primitiva, em Kuzu embarcado | ✅ feito |
| **SPARQL** | que o padrão **não** limita repetição, e a inferência | ✅ feito |
| **GraphQL** | **o que o modelo não consegue expressar**, medido | ✅ feito |
| **T-SQL** | que um `ROLLBACK` aninhado **destrói a transação do chamador** | ✅ feito |
| **PL/SQL** | que `SELECT INTO` é estrito por padrão, e que **todo DDL commita** | ✅ feito |

**As oito estão feitas.** Os dois últimos custaram contêiner, e os tamanhos
estão medidos e não estimados: SQL Server Developer **2,21 GB**, Oracle
Database 23ai Free **13,8 GB** — o registro deste portfólio dizia "~2,5 GB"
para o Oracle, e estava errado por mais de cinco vezes.

As duas edições são gratuitas (Developer é licenciada para desenvolvimento e
teste; Free é gratuita até em produção, com 12 GB de dados e 2 GB de RAM), e
**nenhuma pediu cadastro ou chave**.

E elas não cabem juntas nesta máquina: o WSL2 expõe 3,8 GB, o SQL Server
reserva ~2,6 GB e o Oracle pede 2 GB. Então **cada `roda.sh` para o outro
banco antes de subir o seu**, e a suíte roda os dois em sequência.

## Licença

MIT, em `LICENSE`.
