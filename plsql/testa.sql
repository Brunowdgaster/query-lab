-- testa.sql — exercita a procedure PL/SQL, e MEDE as divergencias do dialeto.
--
-- Casos 1 a 7: os mesmos de `plpgsql/testa.sql` e `tsql/testa.sql`, para que
-- as tres procedures sejam comparaveis caso a caso.
--
-- Casos 8 a 11: comportamentos que so o Oracle tem, e que o cabecalho de
-- `transferir.sql` AFIRMA. Medi-los e a unica forma honesta de documentar:
--
--     8.  `SELECT INTO` estoura NO_DATA_FOUND SOZINHO, sem STRICT e sem IF
--     9.  `RAISE_APPLICATION_ERROR` fora de -20000..-20999 estoura ORA-21000
--     10. todo DDL faz COMMIT IMPLICITO -- e leva o DML pendente com ele
--     11. `PRAGMA EXCEPTION_INIT` deixa o chamador tratar por NOME
--
-- Como nos outros dois, a comparacao e pelo CODIGO do erro e nunca pela
-- mensagem: a mensagem muda com idioma e versao, o codigo e o contrato.

-- `FORMAT WRAPPED` preserva os espacos a esquerda.
--
-- Sem ele o sqlplus APARA o recuo de cada linha de DBMS_OUTPUT, e a saida
-- sai como "ok transferencia..." em vez de "  ok    transferencia...". Nao e
-- cosmetica: o `verifica.sh` dos outros dois dialetos casa pelo texto
-- indentado, e a suite ficaria comparando formatos diferentes entre motores
-- que deveriam ser comparaveis linha a linha.
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF

DECLARE
    v_ok         PLS_INTEGER := 0;
    v_falhou     PLS_INTEGER := 0;
    v_antes      PLS_INTEGER;
    v_depois     PLS_INTEGER;
    v_saldo_novo NUMBER;
    v_esperado   NUMBER;
    v_cod        PLS_INTEGER;
    v_id         pessoa.id%TYPE;

    -- O recurso da secao 3 do cabecalho, declarado aqui para ser medido no
    -- caso 11: liga o numero -20002 a um NOME tratavel.
    saldo_insuficiente EXCEPTION;
    PRAGMA EXCEPTION_INIT(saldo_insuficiente, -20002);

    PROCEDURE diz(p VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p);
    END;
BEGIN
    diz('');
    diz('=== PL/SQL: transferir() ===');
    diz('');

    -- -----------------------------------------------------------------------
    -- CASO 1: transferencia valida grava exatamente uma linha.
    SELECT COUNT(*) INTO v_antes FROM transacao;
    transferir('Ana', 'Carla', 100.00, v_saldo_novo);
    SELECT COUNT(*) INTO v_depois FROM transacao;

    IF v_depois = v_antes + 1 THEN
        diz('  ok    transferencia valida gravou 1 linha');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA transferencia valida: ' || v_depois
            || ' linhas, esperado ' || (v_antes + 1));
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 2: saldo insuficiente estoura -20002, e NADA fica gravado.
    --
    -- O teste que importa: uma procedure que valide o saldo, grave a linha e
    -- so entao estoure deixaria o banco inconsistente, e nenhum teste de
    -- caminho feliz pegaria.
    SELECT COUNT(*) INTO v_antes FROM transacao;
    v_cod := 0;
    BEGIN
        transferir('Ana', 'Carla', 5000.00, v_saldo_novo);
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;
    SELECT COUNT(*) INTO v_depois FROM transacao;

    IF v_cod = -20002 AND v_depois = v_antes THEN
        diz('  ok    saldo insuficiente estoura -20002 e nada foi gravado');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA saldo insuficiente: codigo=' || v_cod
            || ' linhas antes=' || v_antes || ' depois=' || v_depois);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 3: pessoa inexistente -> -20001.
    v_cod := 0;
    BEGIN
        transferir('Ninguem', 'Carla', 10.00, v_saldo_novo);
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;

    IF v_cod = -20001 THEN
        diz('  ok    pessoa inexistente estoura -20001');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA pessoa inexistente deu codigo ' || v_cod);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 4: valor negativo -> -20003.
    v_cod := 0;
    BEGIN
        transferir('Ana', 'Carla', -50.00, v_saldo_novo);
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;

    IF v_cod = -20003 THEN
        diz('  ok    valor negativo estoura -20003');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA valor negativo deu codigo ' || v_cod);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 5: valor zero tambem -> -20003. O limite importa: a procedure diz
    -- `<= 0`, e um teste que so cobrisse negativo nao distinguiria os dois.
    v_cod := 0;
    BEGIN
        transferir('Ana', 'Carla', 0, v_saldo_novo);
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;

    IF v_cod = -20003 THEN
        diz('  ok    valor zero estoura -20003');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA valor zero deu codigo ' || v_cod);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 6: auto-transferencia -> -20004.
    v_cod := 0;
    BEGIN
        transferir('Ana', 'Ana', 10.00, v_saldo_novo);
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;

    IF v_cod = -20004 THEN
        diz('  ok    auto-transferencia estoura -20004');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA auto-transferencia deu codigo ' || v_cod);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 7: o saldo devolvido pelo OUT confere com uma consulta
    -- INDEPENDENTE.
    --
    -- A comparacao e contra uma consulta escrita aqui, e nao contra um numero
    -- fixo: um literal no teste e uma segunda chance de errar a aritmetica, e
    -- este portfolio ja errou exatamente isso -- o banco estava certo e a
    -- expectativa escrita a mao estava errada.
    --
    -- A consulta tambem nao e identica a da procedure (esta soma por JOIN, a
    -- da procedure usa subconsultas correlacionadas), para que as duas nao
    -- compartilhem o mesmo engano.
    SELECT p.saldo_inicial + NVL(e.entrou, 0) - NVL(s.saiu, 0)
      INTO v_esperado
      FROM pessoa p
      LEFT JOIN (SELECT para AS id, SUM(valor) AS entrou
                   FROM transacao GROUP BY para) e ON e.id = p.id
      LEFT JOIN (SELECT de AS id, SUM(valor) AS saiu
                   FROM transacao GROUP BY de) s ON s.id = p.id
     WHERE p.nome = 'Ana';

    v_saldo_novo := NULL;
    transferir('Ana', 'Bruno', 25.00, v_saldo_novo);

    IF v_saldo_novo IS NOT NULL AND v_saldo_novo = v_esperado - 25.00 THEN
        diz('  ok    o OUT confere com a consulta independente ('
            || TO_CHAR(v_saldo_novo) || ')');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA OUT=' || NVL(TO_CHAR(v_saldo_novo), 'NULL')
            || ' esperado=' || TO_CHAR(v_esperado - 25.00));
        v_falhou := v_falhou + 1;
    END IF;

    diz('');
    diz('--- o que so o Oracle faz, medido e nao afirmado ---');
    diz('');

    -- -----------------------------------------------------------------------
    -- CASO 8: `SELECT INTO` estoura SOZINHO, sem STRICT e sem IF.
    --
    -- E a secao 1 do cabecalho, e o contraste e o conteudo:
    --
    --   * aqui: NO_DATA_FOUND, automatico;
    --   * PL/pgSQL: silencioso, a nao ser que se escreva `STRICT`;
    --   * T-SQL: silencioso sempre, e a variavel fica com o valor ANTERIOR --
    --     medido em `tsql/testa.sql`, caso 8, onde -999 continuou -999.
    --
    -- Entao a variavel abaixo tambem comeca com -999, e o teste e se ela
    -- CONTINUA -999 ou se o motor estourou antes de chegar la.
    v_id := -999;
    v_cod := 0;
    BEGIN
        SELECT id INTO v_id FROM pessoa
         WHERE nome = 'NaoExisteNinguemComEsseNome';
        v_cod := 0;
    EXCEPTION WHEN NO_DATA_FOUND THEN
        v_cod := SQLCODE;
    END;

    -- O codigo esperado e +100, e NAO -1403, e descobrir isso foi o unico
    -- caso desta suite que falhou na primeira execucao.
    --
    -- A primeira versao deste teste esperava -1403, porque o erro se chama
    -- ORA-01403 e porque TODO outro codigo do Oracle e o negativo do numero
    -- ORA. O medido foi 100.
    --
    -- O motivo: `NO_DATA_FOUND` e a EXCECAO que o Oracle alinhou com o
    -- padrao ISO/ANSI, onde "nenhuma linha" e a condicao `+100`. Entao
    -- `SQLCODE` devolve +100 para ela, e -1403 nunca aparece ali -- o -1403 e
    -- o numero do erro, nao o valor de SQLCODE.
    --
    -- E uma excecao a regra geral, e o unico jeito de descobrir e medir. A
    -- condicao abaixo exige o 100 E a variavel intocada: as duas afirmacoes
    -- do cabecalho, verificadas juntas.
    IF v_cod = 100 AND v_id = -999 THEN
        diz('  ok    SELECT INTO estourou NO_DATA_FOUND sozinho, com SQLCODE');
        diz('        +100 e nao -1403 (e a excecao que o Oracle alinhou ao');
        diz('        padrao ISO) -- sem STRICT, sem IF EXISTS, e sem deixar a');
        diz('        variavel suja');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA SELECT INTO deu codigo ' || v_cod
            || ' e v_id=' || NVL(TO_CHAR(v_id), 'NULL'));
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 9: fora da faixa -20000..-20999, o proprio
    -- `RAISE_APPLICATION_ERROR` estoura.
    --
    -- Mil codigos e pouco para um sistema grande, e a fronteira e dura: -19999
    -- nao e "um codigo incomum", e um erro de programacao, e o Oracle diz
    -- isso na hora com ORA-21000.
    v_cod := 0;
    BEGIN
        RAISE_APPLICATION_ERROR(-19999, 'fora da faixa');
    EXCEPTION WHEN OTHERS THEN
        v_cod := SQLCODE;
    END;

    IF v_cod = -21000 THEN
        diz('  ok    RAISE_APPLICATION_ERROR(-19999) estoura ORA-21000:');
        diz('        a faixa do usuario e -20000..-20999, mil codigos, e nao');
        diz('        se sai dela por acidente');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA fora da faixa deu codigo ' || v_cod);
        v_falhou := v_falhou + 1;
    END IF;

    -- -----------------------------------------------------------------------
    -- CASO 10: todo DDL faz COMMIT IMPLICITO, e leva o DML pendente.
    --
    -- Nenhum dos outros dois motores faz isso. Grava-se uma linha SEM commit,
    -- executa-se um DDL qualquer, da-se ROLLBACK -- e a linha SOBREVIVE,
    -- porque o DDL ja commitou.
    --
    -- E o tipo de regra que normalmente se aprende depois de perder dados, e
    -- esta aqui como teste justamente para nao precisar.
    INSERT INTO pessoa (id, nome, cidade, saldo_inicial)
    VALUES (9001, 'TempDDL', 'X', 0);

    -- O DDL. `EXECUTE IMMEDIATE` porque PL/SQL nao aceita DDL estatico.
    EXECUTE IMMEDIATE 'CREATE TABLE lixo_ddl (x NUMBER)';

    ROLLBACK;

    SELECT COUNT(*) INTO v_depois FROM pessoa WHERE id = 9001;

    IF v_depois = 1 THEN
        diz('  ok    o DDL fez COMMIT IMPLICITO: a linha inserida ANTES dele');
        diz('        sobreviveu ao ROLLBACK -- nenhum aviso, nenhuma opcao de');
        diz('        desligar isso');
        v_ok := v_ok + 1;
    ELSE
        diz('  FALHA a linha nao sobreviveu: o DDL nao commitou (' || v_depois || ')');
        v_falhou := v_falhou + 1;
    END IF;

    -- Limpeza. O DELETE precisa de commit proprio porque o rollback acima ja
    -- fechou a transacao anterior.
    DELETE FROM pessoa WHERE id = 9001;
    EXECUTE IMMEDIATE 'DROP TABLE lixo_ddl';

    -- -----------------------------------------------------------------------
    -- CASO 11: `PRAGMA EXCEPTION_INIT` deixa tratar por NOME.
    --
    -- A excecao foi declarada no topo deste bloco e ligada a -20002. O
    -- `WHEN saldo_insuficiente` abaixo nao menciona numero nenhum -- e o que
    -- nenhum dos outros dois dialetos permite.
    DECLARE
        v_pegou_por_nome BOOLEAN := FALSE;
    BEGIN
        BEGIN
            transferir('Ana', 'Carla', 999999.00, v_saldo_novo);
        EXCEPTION
            WHEN saldo_insuficiente THEN
                v_pegou_por_nome := TRUE;
        END;

        IF v_pegou_por_nome THEN
            diz('  ok    PRAGMA EXCEPTION_INIT: o chamador escreveu');
            diz('        "WHEN saldo_insuficiente" sem citar -20002 -- o numero');
            diz('        aparece UMA vez, na declaracao');
            v_ok := v_ok + 1;
        ELSE
            diz('  FALHA a excecao nomeada nao capturou o erro');
            v_falhou := v_falhou + 1;
        END IF;
    END;

    -- -----------------------------------------------------------------------
    diz('');
    diz('  ' || v_ok || ' passaram, ' || v_falhou || ' falharam');
    diz('');

    -- Sai com erro se algo falhou, para que o `verifica.sh` leia o RETORNO e
    -- nao precise interpretar a saida.
    IF v_falhou > 0 THEN
        RAISE_APPLICATION_ERROR(-20099, 'ha testes falhando');
    END IF;
END;
/

EXIT
