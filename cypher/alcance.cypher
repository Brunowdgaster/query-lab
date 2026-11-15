// alcance.cypher — "quem está a até 3 saltos de amizade de Ana?", em Cypher.
//
// Compare com `sql/alcance.sql`, que responde a MESMA pergunta em 50 linhas.
//
// ## As três coisas que o SQL faz à mão e aqui não existem
//
// 1. **Espelhar a aresta.** `-[:AMIGO*1..3]-` sem seta já significa "nos dois
//    sentidos". O SQL precisa de um `UNION ALL` espelhando a tabela, porque
//    ela guarda cada amizade uma vez só.
//
// 2. **Controlar o ciclo.** Cypher não repete relacionamento dentro de um
//    mesmo caminho -- é a semântica de *trail* do padrão. O CTE recursivo
//    roda para sempre num grafo com ciclo, e a defesa é carregar o caminho
//    percorrido e testar pertinência a cada passo.
//
// 3. **Contar os saltos.** `length(caminho)` sai do próprio caminho. No SQL a
//    coluna `saltos` é mantida à mão, e um off-by-one ali muda a resposta.
//
// ## O que Cypher NÃO resolve de graça
//
// A travessia devolve **um caminho por rota**, não um nó por pessoa. Elisa é
// alcançável via Carla (2 saltos) e via Fabio (4, fora do limite), então sem
// agregação ela apareceria duas vezes.
//
// O `min(length(caminho))` existe por isso, e é exatamente o mesmo
// `MIN(saltos)` do SQL. **Essa parte não é mais fácil em Cypher** -- e dizer
// isso é o que separa comparação de propaganda.

MATCH caminho = (origem:Pessoa {nome: 'Ana'})-[:AMIGO*1..3]-(p:Pessoa)

// Exclui a origem. A pergunta é "quem está a até 3 saltos DE Ana", e Ana está
// a zero de si mesma -- e num grafo com ciclo ela é alcançável de volta em 2
// ou 3 saltos, então sem este filtro ela APARECERIA no resultado. A mesma
// decisão está explícita nas outras sete implementações.
WHERE p.nome <> 'Ana'

RETURN p.nome AS nome, min(length(caminho)) AS saltos
ORDER BY saltos, nome;
