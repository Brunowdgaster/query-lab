-- testa.sql — exercita a procedure PL/pgSQL, inclusive a ATOMICIDADE.
--
-- O teste que importa não é "a transferência funciona": é que depois de uma
-- falha **nada ficou gravado**. Uma procedure que valida o saldo, grava a
-- linha e só então estoura deixa o banco inconsistente, e nenhum teste de
-- caminho felizmente pegaria isso.
--
-- Cada caso roda em bloco próprio com `EXCEPTION WHEN OTHERS`, capturando o
-- SQLSTATE. Comparar o SQLSTATE, e não a mensagem, é o ponto do `ERRCODE`:
-- a mensagem muda com tradução, o código não.

\set ON_ERROR_STOP on
\pset footer off

DO $$
DECLARE
    -- `v_saldo_novo` existe por uma exigencia do PL/pgSQL que surpreende:
    -- parametro INOUT precisa de argumento GRAVAVEL.
    --
    -- De dentro de um bloco PL/pgSQL, `CALL transferir(..., NULL)` falha com
    -- "is an output parameter but corresponding argument is not writable" --
    -- mesmo que o `CALL` identico funcione quando vem direto do psql, onde o
    -- NULL literal e aceito.
    --
    -- Entao o mesmo comando e valido num contexto e invalido no outro, e a
    -- diferenca nao esta na procedure. T-SQL e PL/SQL nao tem essa assimetria:
    -- la o parametro de saida SEMPRE exige variavel, nos dois contextos.
    v_saldo_novo DECIMAL(12,2);
    v_saldo    DECIMAL(12,2);
    v_antes    INTEGER;
    v_depois   INTEGER;
    v_estado   TEXT;
    v_ok       INTEGER := 0;
    v_falhou   INTEGER := 0;

    PROCEDURE_NAO_EXISTE CONSTANT TEXT := '42883';
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '=== PL/pgSQL: transferir() ===';
    RAISE NOTICE '';

    -- CASO 1: transferência válida.
    SELECT COUNT(*) INTO v_antes FROM transacao;
    CALL transferir('Ana', 'Carla', 100.00, v_saldo_novo);
    SELECT COUNT(*) INTO v_depois FROM transacao;

    IF v_depois = v_antes + 1 THEN
        RAISE NOTICE '  ok    transferencia valida gravou 1 linha';
        v_ok := v_ok + 1;
    ELSE
        RAISE NOTICE '  FALHA transferencia valida: % linhas, esperado %',
                     v_depois, v_antes + 1;
        v_falhou := v_falhou + 1;
    END IF;

    -- CASO 2: saldo insuficiente, e NADA gravado.
    --
    -- Ana tem 834,75 - 100,00 = 734,75 depois do caso 1. Pedir 5000 falha.
    SELECT COUNT(*) INTO v_antes FROM transacao;
    BEGIN
        CALL transferir('Ana', 'Carla', 5000.00, v_saldo_novo);
        RAISE NOTICE '  FALHA saldo insuficiente NAO estourou';
        v_falhou := v_falhou + 1;
    EXCEPTION WHEN OTHERS THEN
        v_estado := SQLSTATE;
        IF v_estado = 'QL002' THEN
            RAISE NOTICE '  ok    saldo insuficiente estoura com QL002';
            v_ok := v_ok + 1;
        ELSE
            RAISE NOTICE '  FALHA saldo insuficiente deu SQLSTATE %', v_estado;
            v_falhou := v_falhou + 1;
        END IF;
    END;

    SELECT COUNT(*) INTO v_depois FROM transacao;
    IF v_depois = v_antes THEN
        RAISE NOTICE '  ok    nada gravado apos a falha (atomicidade)';
        v_ok := v_ok + 1;
    ELSE
        RAISE NOTICE '  FALHA sobrou linha apos falha: % -> %', v_antes, v_depois;
        v_falhou := v_falhou + 1;
    END IF;

    -- CASO 3: pessoa inexistente -> QL001.
    BEGIN
        CALL transferir('Ana', 'Ninguem', 10.00, v_saldo_novo);
        RAISE NOTICE '  FALHA pessoa inexistente NAO estourou';
        v_falhou := v_falhou + 1;
    EXCEPTION WHEN OTHERS THEN
        v_estado := SQLSTATE;
        IF v_estado = 'QL001' THEN
            RAISE NOTICE '  ok    pessoa inexistente estoura com QL001';
            v_ok := v_ok + 1;
        ELSE
            RAISE NOTICE '  FALHA pessoa inexistente deu SQLSTATE %', v_estado;
            v_falhou := v_falhou + 1;
        END IF;
    END;

    -- CASO 4: valor negativo -> QL003.
    BEGIN
        CALL transferir('Ana', 'Carla', -50.00, v_saldo_novo);
        RAISE NOTICE '  FALHA valor negativo NAO estourou';
        v_falhou := v_falhou + 1;
    EXCEPTION WHEN OTHERS THEN
        v_estado := SQLSTATE;
        IF v_estado = 'QL003' THEN
            RAISE NOTICE '  ok    valor negativo estoura com QL003';
            v_ok := v_ok + 1;
        ELSE
            RAISE NOTICE '  FALHA valor negativo deu SQLSTATE %', v_estado;
            v_falhou := v_falhou + 1;
        END IF;
    END;

    -- CASO 5: valor zero tambem -> QL003. O limite importa: `<= 0` e nao
    -- `< 0`, porque transferir zero e operacao sem efeito que polui o
    -- historico.
    BEGIN
        CALL transferir('Ana', 'Carla', 0.00, v_saldo_novo);
        RAISE NOTICE '  FALHA valor zero NAO estourou';
        v_falhou := v_falhou + 1;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'QL003' THEN
            RAISE NOTICE '  ok    valor zero estoura com QL003';
            v_ok := v_ok + 1;
        ELSE
            RAISE NOTICE '  FALHA valor zero deu SQLSTATE %', SQLSTATE;
            v_falhou := v_falhou + 1;
        END IF;
    END;

    -- CASO 6: auto-transferencia -> QL004.
    BEGIN
        CALL transferir('Ana', 'Ana', 10.00, v_saldo_novo);
        RAISE NOTICE '  FALHA auto-transferencia NAO estourou';
        v_falhou := v_falhou + 1;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'QL004' THEN
            RAISE NOTICE '  ok    auto-transferencia estoura com QL004';
            v_ok := v_ok + 1;
        ELSE
            RAISE NOTICE '  FALHA auto-transferencia deu SQLSTATE %', SQLSTATE;
            v_falhou := v_falhou + 1;
        END IF;
    END;

    -- CASO 7: o saldo devolvido pelo INOUT confere com a consulta ANSI.
    --
    -- Isto e verificacao CRUZADA, nao redundancia: a procedure calcula o
    -- saldo novo por subtracao, e `sql/saldo.sql` o recalcula somando as
    -- transacoes. Se os dois divergirem, um dos dois esta errado.
    CALL transferir('Bruno', 'Elisa', 200.00, v_saldo_novo) ;
    SELECT p.saldo_inicial
             + COALESCE((SELECT SUM(t.valor) FROM transacao t WHERE t.para = p.id), 0)
             - COALESCE((SELECT SUM(t.valor) FROM transacao t WHERE t.de = p.id), 0)
      INTO v_saldo FROM pessoa p WHERE p.nome = 'Bruno';

    -- Bruno (id 2): 1000 inicial
    --              + 150,00  recebeu de Ana        (transacao 1)
    --              -  80,50  enviou a Diego        (transacao 2)
    --              -  30,00  enviou a Ana          (transacao 10)
    --              - 200,00  enviou a Elisa        (este teste)
    --              = 839,50
    --
    -- A primeira versao deste comentario somava os 30,00 como ENTRADA, e
    -- esperava 899,50. A transacao 10 e `de=2, para=1`: Bruno ENVIA a Ana.
    -- Errar o sinal custa o dobro do valor -- 60,00 -- e foi exatamente a
    -- diferenca que apareceu.
    --
    -- O teste pegou um erro meu de aritmetica, nao um erro do banco, e isso e
    -- o resultado certo: a verificacao cruzada serve justamente para quando a
    -- expectativa esta errada. Conferir: Ana tem 834,75 = 1000 + 30 - 150 -
    -- 45,25, o que so fecha se os 30,00 forem ENTRADA dela.
    IF v_saldo = 839.50 THEN
        RAISE NOTICE '  ok    saldo apos transferencia confere (839.50)';
        v_ok := v_ok + 1;
    ELSE
        RAISE NOTICE '  FALHA saldo de Bruno deu %, esperado 839.50', v_saldo;
        v_falhou := v_falhou + 1;
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '  % passaram, % falharam', v_ok, v_falhou;
    RAISE NOTICE '';

    IF v_falhou > 0 THEN
        RAISE EXCEPTION 'PL/pgSQL: % teste(s) falharam', v_falhou;
    END IF;
END;
$$;
