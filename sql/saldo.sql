-- saldo.sql — o saldo de cada pessoa, em SQL ANSI.
--
-- Roda em SQLite e em PostgreSQL sem alteração. É a regra que as procedures
-- dos três dialetos têm de respeitar, e por isso vive aqui, numa consulta
-- única -- em vez de repetida dentro de cada procedure, onde divergiria.
--
-- `COALESCE` nos dois lados: uma pessoa sem transação nenhuma tem SUM() nulo,
-- não zero. É a diferença entre "não há linhas" e "a soma é zero", e esquecer
-- disso faz o saldo de quem nunca transacionou virar NULL -- que então se
-- propaga por toda comparação, silenciosamente, porque NULL > 0 não é falso,
-- é NULL.

SELECT
    p.nome,
    p.saldo_inicial
      + COALESCE((SELECT SUM(t.valor) FROM transacao t WHERE t.para = p.id), 0)
      - COALESCE((SELECT SUM(t.valor) FROM transacao t WHERE t.de   = p.id), 0)
      AS saldo
FROM pessoa p
ORDER BY p.nome;
