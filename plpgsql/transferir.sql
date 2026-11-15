-- transferir.sql — a mesma procedure, em PL/pgSQL (PostgreSQL).
--
-- Esta é a primeira das três versões do MESMO procedimento. As outras estão em
-- `plsql/transferir.sql` (Oracle) e `tsql/transferir.sql` (SQL Server), e as
-- três são comparadas lado a lado em `COMPARACAO.md`.
--
-- A regra de negócio é idêntica nas três, e deliberadamente simples:
--
--     transferir(de, para, valor) grava uma transação, desde que
--       * as duas pessoas existam;
--       * não sejam a mesma;
--       * o valor seja positivo;
--       * e o saldo de quem envia cubra o valor.
--
-- O que NÃO é idêntico — e é o assunto — é como cada fornecedor:
--
--   1. declara o bloco procedural;
--   2. sinaliza erro de regra de negócio;
--   3. controla a transação;
--   4. e devolve valor ao chamador.
--
-- ## 1. O bloco: `$$ ... $$`
--
-- O corpo da procedure é uma STRING para o PostgreSQL, delimitada por
-- *dollar quoting*. Isso tem uma consequência prática que surpreende: erro de
-- sintaxe no corpo não é pego no `CREATE PROCEDURE` -- ele é pego quando a
-- procedure RODA, porque até então o corpo é texto opaco.
--
-- Oracle e SQL Server compilam o corpo na criação. É a favor deles.
--
-- (PostgreSQL 14+ aceita `BEGIN ATOMIC` em funções SQL, que é compilado na
-- criação. Não se aplica a PL/pgSQL.)
--
-- ## 2. Sinalizar erro: `RAISE EXCEPTION ... USING ERRCODE`
--
-- O `ERRCODE` é o que torna o erro TRATÁVEL pelo chamador. Sem ele, todo erro
-- de regra de negócio vira `P0001` (`raise_exception`), e quem chama só pode
-- distinguir por substring da mensagem -- que quebra quando a mensagem é
-- traduzida.
--
-- ### Por que `QL***`, e não `P0***`
--
-- A primeira versão deste arquivo usava `P0001`..`P0004`, com um comentário
-- afirmando que a classe `P0` é reservada ao usuário. **Isso é falso**, e os
-- quatro códigos colidiam com códigos do próprio PostgreSQL:
--
--     P0001  raise_exception  <- o generico de TODO `RAISE` sem ERRCODE
--     P0002  no_data_found
--     P0003  too_many_rows
--     P0004  assert_failure
--
-- A colisão com `P0004` deu o sintoma alto: **`EXCEPTION WHEN OTHERS` se
-- recusa a capturar `assert_failure`** -- é documentado, junto com
-- `query_canceled`, e foi medido aqui: nem um `WHEN OTHERS` externo pegou. O
-- erro de auto-transferência era, por construção, intratável.
--
-- As outras três são piores por serem SILENCIOSAS:
--
--   * `P0002` significaria que "saldo insuficiente" é indistinguível de um
--     `SELECT INTO STRICT` que não achou linha -- e esta procedure usa
--     exatamente isso duas vezes. Um chamador que reagisse a `P0002`
--     recarregando saldo reagiria também a um bug de linha faltando;
--   * `P0003` colide com `too_many_rows`, que esta procedure também pode
--     levantar;
--   * `P0001` é o código que TODO `RAISE EXCEPTION` sem `ERRCODE` recebe, em
--     qualquer lugar do sistema -- então "pessoa não encontrada" seria
--     indistinguível de qualquer erro não codificado.
--
-- E os testes PASSAVAM em três das quatro colisões, porque o teste conferia o
-- mesmo código errado que a procedure levantava. Dois lados concordando não é
-- verificação quando os dois saem da mesma premissa falsa.
--
-- A classe `QL` é legítima: a ISO reserva as classes que começam com `5`-`9`
-- ou `I`-`Z` para o implementador, e o PostgreSQL não usa nenhuma delas. Que
-- `QL004` é capturável por `WHEN OTHERS` foi medido, não suposto.
--
-- ## 3. A transação: PROCEDURE, não FUNCTION
--
-- Esta é a diferença estrutural mais importante, e a menos conhecida:
--
--   * uma FUNCTION em PostgreSQL roda SEMPRE dentro da transação do chamador,
--     e não pode dar COMMIT nem ROLLBACK;
--   * uma PROCEDURE (PostgreSQL 11+), chamada com `CALL` fora de transação
--     explícita, PODE.
--
-- Esta é uma PROCEDURE, mas de propósito NÃO dá COMMIT: ela deixa a
-- transação com o chamador, para que várias transferências possam ser
-- atômicas em conjunto. É a decisão certa para uma operação de negócio, e é a
-- oposta da que o PL/SQL da Oracle toma por hábito -- ver `COMPARACAO.md`.
--
-- ## 4. Devolver valor: parâmetro `INOUT`
--
-- Procedure em PostgreSQL não tem `RETURN valor`. O jeito é um parâmetro
-- `INOUT`, e o chamador lê a coluna que o `CALL` devolve. T-SQL usa `OUTPUT`,
-- que é parecido; PL/SQL usa `OUT`, que é igual em espírito.

CREATE OR REPLACE PROCEDURE transferir(
    p_de     VARCHAR(40),
    p_para   VARCHAR(40),
    p_valor  DECIMAL(12,2),
    -- INOUT e nao OUT: o PostgreSQL exige que o chamador passe um valor para
    -- parametro INOUT (tipicamente NULL), e em troca a procedure pode ser
    -- chamada por `CALL` com a saida vindo como linha de resultado.
    p_saldo_novo INOUT DECIMAL(12,2) DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_de    INTEGER;
    v_id_para  INTEGER;
    v_saldo    DECIMAL(12,2);
    v_prox_id  INTEGER;
BEGIN
    -- Validação do valor ANTES de tocar o banco: é a mais barata, e falhar
    -- cedo deixa a mensagem de erro mais específica.
    IF p_valor IS NULL OR p_valor <= 0 THEN
        RAISE EXCEPTION 'valor deve ser positivo, recebido: %', p_valor
            USING ERRCODE = 'QL003';
    END IF;

    -- `STRICT` é o que transforma "não achou" em exceção.
    --
    -- Sem ele, um SELECT INTO que não acha nada deixa a variável NULL e
    -- SEGUE EM FRENTE -- e a falha aparece muito depois, como violação de
    -- NOT NULL no INSERT, com mensagem que não menciona o nome errado. É o
    -- erro mais comum de quem escreve PL/pgSQL.
    --
    -- `NO_DATA_FOUND` é o nome do PostgreSQL para o mesmo que a Oracle chama
    -- `NO_DATA_FOUND` (coincidem) e o SQL Server não tem: lá o padrão é
    -- testar `@@ROWCOUNT` ou `IF NOT EXISTS`.
    BEGIN
        SELECT id INTO STRICT v_id_de FROM pessoa WHERE nome = p_de;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE EXCEPTION 'pessoa não encontrada: %', p_de
                USING ERRCODE = 'QL001';
        WHEN TOO_MANY_ROWS THEN
            RAISE EXCEPTION 'nome ambíguo: %', p_de
                USING ERRCODE = 'QL001';
    END;

    BEGIN
        SELECT id INTO STRICT v_id_para FROM pessoa WHERE nome = p_para;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE EXCEPTION 'pessoa não encontrada: %', p_para
                USING ERRCODE = 'QL001';
        WHEN TOO_MANY_ROWS THEN
            RAISE EXCEPTION 'nome ambíguo: %', p_para
                USING ERRCODE = 'QL001';
    END;

    IF v_id_de = v_id_para THEN
        RAISE EXCEPTION 'origem e destino são a mesma pessoa: %', p_de
            USING ERRCODE = 'QL004';
    END IF;

    -- O saldo. A regra é a mesma de `sql/saldo.sql`, e o COALESCE existe
    -- pelo mesmo motivo: quem nunca transacionou tem SUM() nulo, não zero, e
    -- NULL <= valor não é falso, é NULL -- o que faria a comparação de saldo
    -- passar silenciosamente.
    SELECT p.saldo_inicial
             + COALESCE((SELECT SUM(t.valor) FROM transacao t
                          WHERE t.para = p.id), 0)
             - COALESCE((SELECT SUM(t.valor) FROM transacao t
                          WHERE t.de = p.id), 0)
      INTO v_saldo
      FROM pessoa p
     WHERE p.id = v_id_de;

    IF v_saldo < p_valor THEN
        RAISE EXCEPTION 'saldo insuficiente: % tem %, tentou enviar %',
                        p_de, v_saldo, p_valor
            USING ERRCODE = 'QL002';
    END IF;

    -- O id da transação vem de MAX+1 e não de uma sequência, porque o
    -- esquema é ANSI e compartilhado com SQLite, que não tem sequência.
    --
    -- Em produção isto seria ERRADO: duas transações concorrentes leriam o
    -- mesmo MAX e colidiriam na PRIMARY KEY. A escolha é consciente, e o
    -- comentário existe para que ninguém a copie pensando que é um padrão.
    SELECT COALESCE(MAX(id), 0) + 1 INTO v_prox_id FROM transacao;

    INSERT INTO transacao (id, de, para, valor, data)
    VALUES (v_prox_id, v_id_de, v_id_para, p_valor, CURRENT_DATE);

    p_saldo_novo := v_saldo - p_valor;

    -- SEM COMMIT, de propósito.
    --
    -- A procedure deixa a transação com o chamador. Se ela desse COMMIT aqui,
    -- duas transferências que precisam ser atômicas EM CONJUNTO não poderiam
    -- ser -- e esse é o caso de uso real de uma operação de valor.
    --
    -- É a decisão oposta à que o PL/SQL da Oracle toma por hábito, e a
    -- comparação está em COMPARACAO.md.
END;
$$;
