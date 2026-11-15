-- esquema.sql — o domínio em relacional, em SQL ANSI.
--
-- Roda em SQLite e em PostgreSQL **sem alteração**, e isso é deliberado: o
-- projeto compara MODELOS DE DADOS, e misturar diferença de modelo com
-- diferença de dialeto tornaria a comparação inútil.
--
-- O que ficou de fora por não ser ANSI:
--
--   * `SERIAL` / `AUTOINCREMENT` — os ids vêm do CSV, então não há sequência;
--   * `CHECK` com subconsulta — o SQLite aceita, o Postgres recusa;
--   * `ON CONFLICT` — sintaxe divergente, e a carga é sempre em tabela vazia.
--
-- As diferenças de dialeto aparecem de propósito nos arquivos dos três
-- dialetos procedurais (`plpgsql/`, `plsql/`, `tsql/`), onde elas são o
-- assunto.

CREATE TABLE pessoa (
    id     INTEGER     NOT NULL PRIMARY KEY,
    nome   VARCHAR(40) NOT NULL,
    cidade VARCHAR(40) NOT NULL,
    -- O saldo inicial existe para a regra de negocio das procedures ter o que
    -- violar: sem ele, "saldo insuficiente" nunca aconteceria, e os tres
    -- dialetos procedurais nao teriam excecao para tratar -- que e justamente
    -- onde eles divergem.
    saldo_inicial DECIMAL(12,2) NOT NULL
);

-- A amizade é NÃO DIRIGIDA, e a tabela guarda cada aresta UMA vez.
--
-- A alternativa seria guardar os dois sentidos e dobrar as linhas. Guardar um
-- sentido e espelhar na consulta é o que o modelo relacional pede, e é a
-- primeira diferença visível em relação ao Cypher, onde `-[:AMIGO]-` sem seta
-- já significa "nos dois sentidos".
--
-- `a < b` como CHECK garante a forma canônica: sem isso, (1,2) e (2,1)
-- poderiam coexistir e a consulta contaria o mesmo amigo duas vezes.
CREATE TABLE amizade (
    a INTEGER NOT NULL REFERENCES pessoa (id),
    b INTEGER NOT NULL REFERENCES pessoa (id),
    PRIMARY KEY (a, b),
    CHECK (a < b)
);

CREATE TABLE transacao (
    id    INTEGER       NOT NULL PRIMARY KEY,
    de    INTEGER       NOT NULL REFERENCES pessoa (id),
    para  INTEGER       NOT NULL REFERENCES pessoa (id),
    valor DECIMAL(12,2) NOT NULL,
    data  DATE          NOT NULL,
    CHECK (valor > 0),
    CHECK (de <> para)
);

-- Índice nos dois sentidos da amizade.
--
-- A PRIMARY KEY (a, b) já serve as buscas por `a`, mas o CTE recursivo
-- precisa casar por `b` também -- é o preço de guardar a aresta uma vez só.
-- Em Cypher o índice do relacionamento é do próprio modelo.
CREATE INDEX idx_amizade_b ON amizade (b);

CREATE INDEX idx_transacao_de ON transacao (de);
CREATE INDEX idx_transacao_para ON transacao (para);
