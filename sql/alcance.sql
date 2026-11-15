-- alcance.sql — "quem está a até 3 saltos de amizade de Ana?", em SQL ANSI.
--
-- Roda sem alteração em SQLite e em PostgreSQL.
--
-- ## O que este arquivo mostra
--
-- A mesma pergunta é **uma expressão** em Cypher:
--
--     MATCH (a:Pessoa {nome:'Ana'})-[:AMIGO*1..3]-(p) RETURN p.nome
--
-- Em SQL ela é um CTE recursivo com três coisas que o Cypher resolve sozinho:
--
--   1. **espelhar a aresta** -- a amizade é não dirigida e a tabela guarda um
--      sentido, então cada passo precisa de dois `JOIN` ou de um `UNION`;
--   2. **controlar o ciclo** -- um CTE recursivo sobre grafo com ciclo roda
--      para sempre, e a defesa é carregar o caminho e testar pertinência;
--   3. **contar os saltos** -- a coluna `saltos` é mantida à mão, e um
--      off-by-one aqui muda a resposta (Gabi, a 4 saltos, entraria).
--
-- Nenhuma das três é dificuldade acidental: elas são o que significa não ter
-- travessia no modelo.
--
-- ## Por que o caminho é um texto, e não um array
--
-- Postgres tem `ARRAY` e `= ANY`, e seria mais limpo. SQLite não tem.
--
-- Como o projeto compara modelos e não dialetos, o controle de ciclo usa
-- concatenação de texto com separadores -- `',1,2,'` -- e testa pertinência
-- com `LIKE`. É mais feio e roda nos dois.
--
-- Os delimitadores em volta de cada id NÃO são decoração: sem eles, procurar
-- o id `1` casaria dentro de `12`, e o filtro de ciclo cortaria caminhos
-- válidos em silêncio. É o bug clássico de "contains" em lista serializada.

WITH RECURSIVE
-- Espelha a amizade: cada aresta nos dois sentidos, para a travessia não ter
-- de saber de qual lado o id está.
aresta (origem, destino) AS (
    SELECT a, b FROM amizade
    UNION ALL
    SELECT b, a FROM amizade
),

-- A travessia. O caso base é a própria Ana, com zero saltos.
alcance (id, saltos, caminho) AS (
    SELECT
        p.id,
        0,
        ',' || CAST(p.id AS VARCHAR(10)) || ','
    FROM pessoa p
    WHERE p.nome = 'Ana'

    UNION ALL

    SELECT
        e.destino,
        a.saltos + 1,
        a.caminho || CAST(e.destino AS VARCHAR(10)) || ','
    FROM alcance a
    JOIN aresta e ON e.origem = a.id
    WHERE a.saltos < 3
      -- O controle de ciclo. Sem ele, Ana->Bruno->Ana->Bruno... não termina.
      AND a.caminho NOT LIKE '%,' || CAST(e.destino AS VARCHAR(10)) || ',%'
)

-- `MIN(saltos)`: a travessia acha o mesmo nó por caminhos diferentes, e a
-- pergunta é a DISTÂNCIA, que é o menor deles. Sem o MIN, Elisa apareceria
-- duas vezes (via Carla com 2 saltos, e via Fabio com 4 -- este último
-- cortado pelo limite, mas em grafo maior apareceria).
--
-- Em Cypher, `-[:AMIGO*1..3]-` também devolve um nó por caminho, e o
-- `shortestPath` ou um `min()` são igualmente necessários. A diferença não é
-- essa; é tudo o que vem acima.
SELECT
    p.nome   AS nome,
    MIN(a.saltos) AS saltos
FROM alcance a
JOIN pessoa p ON p.id = a.id
-- Exclui a origem: a pergunta é "quem está a até 3 saltos DE Ana", e Ana está
-- a zero de si mesma. A mesma decisão está explícita nas outras sete
-- implementações.
WHERE a.saltos > 0
GROUP BY p.nome
ORDER BY MIN(a.saltos), p.nome;
