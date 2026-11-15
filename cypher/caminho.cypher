// caminho.cypher — "qual o menor caminho de amizade de Ana até Gabi?"
//
// Esta é a pergunta em que o Cypher ganha por mais margem, e vale dizer por
// quê com precisão.
//
// Em SQL, achar O MENOR caminho exige:
//
//   * gerar TODOS os caminhos com um CTE recursivo (sem limite de saltos,
//     porque não se sabe onde está o destino);
//   * carregar cada caminho percorrido como texto, para controlar ciclo;
//   * ordenar por comprimento e pegar o primeiro.
//
// Ou seja: o SQL **enumera para depois escolher**. O custo cresce com o
// número de caminhos, não com o do menor.
//
// Aqui é uma função, e o motor faz busca em largura -- para no primeiro
// caminho encontrado, que é necessariamente o mais curto.
//
// `* SHORTEST` é a sintaxe do Kuzu, alinhada ao padrão GQL. O Neo4j clássico
// escreve `shortestPath((a)-[:AMIGO*]-(b))`, que é a mesma coisa com sintaxe
// anterior ao padrão.
//
// `nodes(caminho)` dá os nós na ordem, e `length(caminho)` o número de
// relacionamentos -- que é o número de saltos. O caminho tem 5 nós e 4
// saltos, e confundir os dois é o off-by-one clássico desta consulta.
//
// ## Duas medições que mudaram esta consulta
//
// **`SHORTEST 1` compila e devolve ZERO linhas.** Foi a primeira forma
// escrita aqui, e o binder do Kuzu a aceitou sem reclamar. Uma verificação
// que só perguntasse "compila?" teria aprovado uma consulta que não responde
// nada. `SHORTEST` sozinho, ou `SHORTEST 1..10`, funciona.
//
// **`ALL SHORTEST` devolve um caminho DIFERENTE, e igualmente correto:**
//
//     SHORTEST       Ana -> Bruno -> Diego -> Fabio -> Gabi   4 saltos
//     ALL SHORTEST   Ana -> Carla -> Elisa -> Fabio -> Gabi   4 saltos
//
// Ana alcança Fabio pelos dois lados do ciclo, com o mesmo comprimento. **O
// menor caminho não é único**, e qual deles sai é escolha do motor.
//
// Por isso a suíte não compara o caminho literalmente: ela VALIDA que é um
// caminho (extremos certos, cada passo é uma amizade real, nenhum nó
// repetido) com o número certo de saltos. Ver `python/valida_caminho.py`.
//
// `list_transform` em vez da compreensão `[n IN nodes(c) | n.nome]`: a
// compreensão de lista do Cypher do Neo4j não é aceita pelo Kuzu 0.11.3, que
// responde "Variable n is not in scope". É uma das divergências reais entre
// os dois dialetos de Cypher.

MATCH caminho = (a:Pessoa {nome: 'Ana'})-[:AMIGO* SHORTEST]-(b:Pessoa {nome: 'Gabi'})
RETURN list_transform(nodes(caminho), x -> x.nome) AS caminho,
       length(caminho) AS saltos;
