-- testa.sql — exercita a procedure T-SQL, e MEDE as divergencias do dialeto.
--
-- Os casos 1 a 7 sao os mesmos de `plpgsql/testa.sql`, para que as duas
-- procedures sejam comparaveis caso a caso.
--
-- Os casos 8 a 11 nao existem no PL/pgSQL porque medem comportamentos que so
-- o T-SQL tem -- e existem porque o cabeçalho de `transferir.sql` AFIRMA
-- esses comportamentos. Afirmacao sobre o motor sem medicao e exatamente o
-- que este portfolio ja errou varias vezes:
--
--     8.  atribuicao que nao acha nada deixa a variavel INTOCADA
--     9.  `BEGIN TRAN` aninhado so incrementa @@TRANCOUNT, e UM `ROLLBACK`
--         desfaz todos os niveis
--     10. `THROW` preserva o numero do erro e `RAISERROR` o achata em 50000
--     11. esta procedure NAO abre transacao -- a afirmacao da secao 4
--
-- Cada caso compara o NUMERO do erro, nunca a mensagem: a mensagem muda com
-- idioma e com versao, o numero e o contrato.

SET NOCOUNT ON;
GO

DECLARE @ok      INTEGER = 0,
        @falhou  INTEGER = 0,
        @antes   INTEGER,
        @depois  INTEGER,
        @saldo   DECIMAL(12,2),
        @esperado DECIMAL(12,2),
        @saldo_novo DECIMAL(12,2),
        @num     INTEGER,
        @tc      INTEGER,
        @msg     NVARCHAR(400);

PRINT '';
PRINT '=== T-SQL: transferir() ===';
PRINT '';

-- ---------------------------------------------------------------------------
-- CASO 1: transferencia valida grava exatamente uma linha.
SELECT @antes = COUNT(*) FROM transacao;
BEGIN TRY
    EXEC transferir 'Ana', 'Carla', 100.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    PRINT CONCAT('  FALHA transferencia valida estourou: ', ERROR_MESSAGE());
    SET @falhou = @falhou + 1;
END CATCH
SELECT @depois = COUNT(*) FROM transacao;

IF @depois = @antes + 1
BEGIN
    PRINT '  ok    transferencia valida gravou 1 linha';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA transferencia valida: ', @depois,
                 ' linhas, esperado ', @antes + 1);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 2: saldo insuficiente estoura 50002, e NADA fica gravado.
--
-- Este e o teste que importa: uma procedure que valide o saldo, grave a linha
-- e so entao estoure deixaria o banco inconsistente, e um teste de caminho
-- feliz nao pegaria isso.
SELECT @antes = COUNT(*) FROM transacao;
SET @num = 0;
BEGIN TRY
    EXEC transferir 'Ana', 'Carla', 5000.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    SET @num = ERROR_NUMBER();
END CATCH
SELECT @depois = COUNT(*) FROM transacao;

IF @num = 50002 AND @depois = @antes
BEGIN
    PRINT '  ok    saldo insuficiente estoura 50002 e nada foi gravado';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA saldo insuficiente: erro=', @num,
                 ' linhas antes=', @antes, ' depois=', @depois);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 3: pessoa inexistente -> 50001.
SET @num = 0;
BEGIN TRY
    EXEC transferir 'Ninguem', 'Carla', 10.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    SET @num = ERROR_NUMBER();
END CATCH

IF @num = 50001
BEGIN
    PRINT '  ok    pessoa inexistente estoura 50001';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA pessoa inexistente deu erro ', @num);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 4: valor negativo -> 50003.
SET @num = 0;
BEGIN TRY
    EXEC transferir 'Ana', 'Carla', -50.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    SET @num = ERROR_NUMBER();
END CATCH

IF @num = 50003
BEGIN
    PRINT '  ok    valor negativo estoura 50003';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA valor negativo deu erro ', @num);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 5: valor zero tambem -> 50003. O limite importa: a procedure diz
-- `<= 0`, e nao `< 0`, e um teste que só cobrisse negativo nao distinguiria
-- os dois.
SET @num = 0;
BEGIN TRY
    EXEC transferir 'Ana', 'Carla', 0.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    SET @num = ERROR_NUMBER();
END CATCH

IF @num = 50003
BEGIN
    PRINT '  ok    valor zero estoura 50003';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA valor zero deu erro ', @num);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 6: auto-transferencia -> 50004.
--
-- No PostgreSQL este caso tinha um historico: o codigo original era `P0004`,
-- que colide com `assert_failure`, e `EXCEPTION WHEN OTHERS` se RECUSA a
-- capturar esse -- o erro era intratavel por construcao. No T-SQL a colisao
-- nao e possivel, porque 50004 esta acima da fronteira do usuario.
SET @num = 0;
BEGIN TRY
    EXEC transferir 'Ana', 'Ana', 10.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    SET @num = ERROR_NUMBER();
END CATCH

IF @num = 50004
BEGIN
    PRINT '  ok    auto-transferencia estoura 50004';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA auto-transferencia deu erro ', @num);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 7: o saldo devolvido pelo OUTPUT confere com a consulta independente.
--
-- A comparacao e contra uma consulta escrita AQUI, e nao contra um numero
-- fixo: um literal no teste e uma segunda chance de errar a aritmetica, e
-- este portfolio ja errou exatamente isso uma vez -- o banco estava certo e a
-- expectativa escrita a mao estava errada.
--
-- A consulta nao e identica a da procedure (esta soma por JOIN, a da
-- procedure usa subconsultas correlacionadas), para que as duas nao
-- compartilhem o mesmo engano.
SELECT @esperado = p.saldo_inicial
                 + ISNULL(e.entrou, 0)
                 - ISNULL(s.saiu, 0)
  FROM pessoa p
  LEFT JOIN (SELECT para AS id, SUM(valor) AS entrou
               FROM transacao GROUP BY para) e ON e.id = p.id
  LEFT JOIN (SELECT de AS id, SUM(valor) AS saiu
               FROM transacao GROUP BY de) s ON s.id = p.id
 WHERE p.nome = 'Ana';

SET @saldo_novo = NULL;
BEGIN TRY
    EXEC transferir 'Ana', 'Bruno', 25.00, @saldo_novo OUTPUT;
END TRY
BEGIN CATCH
    PRINT CONCAT('  FALHA caso 7 estourou: ', ERROR_MESSAGE());
END CATCH

IF @saldo_novo IS NOT NULL AND @saldo_novo = @esperado - 25.00
BEGIN
    PRINT CONCAT('  ok    o OUTPUT confere com a consulta independente (',
                 CONVERT(VARCHAR(20), @saldo_novo), ')');
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA OUTPUT=', ISNULL(CONVERT(VARCHAR(20), @saldo_novo), 'NULL'),
                 ' esperado=', CONVERT(VARCHAR(20), @esperado - 25.00));
    SET @falhou = @falhou + 1;
END

PRINT '';
PRINT '--- o que so o T-SQL faz, medido e nao afirmado ---';
PRINT '';

-- ---------------------------------------------------------------------------
-- CASO 8: a atribuicao que nao acha nada deixa a variavel INTOCADA.
--
-- Este e o comportamento que justifica cada `IF NOT EXISTS` da procedure. No
-- PL/pgSQL, `SELECT INTO STRICT` estouraria; aqui a variavel guarda o valor
-- ANTERIOR, e o codigo segue com o id errado.
--
-- Medir isso e o unico jeito honesto de documentar: e contraintuitivo o
-- suficiente para que "eu acho que o T-SQL faz X" nao sirva.
DECLARE @v_teste INTEGER = -999;
SELECT @v_teste = id FROM pessoa WHERE nome = 'NaoExisteNinguemComEsseNome';

IF @v_teste = -999
BEGIN
    PRINT '  ok    atribuicao sem linha deixa a variavel INTOCADA (-999, nao NULL)';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA a variavel virou ',
                 ISNULL(CONVERT(VARCHAR(20), @v_teste), 'NULL'),
                 ' -- o motor mudou de comportamento, e a procedure precisa ser revista');
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 9: `BEGIN TRAN` aninhado so incrementa, e UM `ROLLBACK` desfaz tudo.
--
-- E a razao da secao 4 do cabecalho: se a procedure abrisse transacao e
-- desse rollback, levaria a do chamador junto.
BEGIN TRAN;                        -- nivel 1: o "chamador"
    INSERT INTO pessoa (id, nome, cidade, saldo_inicial)
    VALUES (9001, 'Temp1', 'X', 0);

    BEGIN TRAN;                    -- nivel 2: a "procedure"
        SET @tc = @@TRANCOUNT;
        INSERT INTO pessoa (id, nome, cidade, saldo_inicial)
        VALUES (9002, 'Temp2', 'X', 0);
    ROLLBACK;                      -- UM rollback...

SET @depois = @@TRANCOUNT;

-- ...e os dois niveis se foram, junto com a linha do nivel 1.
IF @tc = 2 AND @depois = 0
   AND NOT EXISTS (SELECT 1 FROM pessoa WHERE id IN (9001, 9002))
BEGIN
    PRINT '  ok    BEGIN TRAN aninhado so incrementa (@@TRANCOUNT=2), e UM';
    PRINT '        ROLLBACK zerou os dois niveis e apagou a linha do CHAMADOR';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    -- A contagem vai para uma variavel ANTES do PRINT, e nao embutida nele.
    --
    -- `PRINT` so aceita expressao escalar: uma subconsulta dentro dele e erro
    -- 1046, "Subqueries are not allowed in this context". E a primeira versao
    -- deste arquivo tinha exatamente isso -- com uma consequencia que vale
    -- registrar: por ser erro de COMPILACAO do lote, nenhum dos 11 casos
    -- rodou. Um erro de sintaxe num galho que so executa em caso de falha
    -- derrubou a suite inteira, e o T-SQL compila o lote todo antes de
    -- executar qualquer linha dele.
    DECLARE @sobrou INTEGER;
    SELECT @sobrou = COUNT(*) FROM pessoa WHERE id IN (9001, 9002);
    PRINT CONCAT('  FALHA aninhamento: @@TRANCOUNT interno=', @tc,
                 ' depois do rollback=', @depois,
                 ' linhas sobreviventes=', @sobrou);
    SET @falhou = @falhou + 1;
    IF @@TRANCOUNT > 0 ROLLBACK;
    DELETE FROM pessoa WHERE id IN (9001, 9002);
END

-- ---------------------------------------------------------------------------
-- CASO 10: `THROW` preserva o numero; `RAISERROR` achata em 50000.
--
-- E a limitacao da secao 2, medida. Note que o RAISERROR aqui usa `%s` e
-- FUNCIONA como formatacao -- o que ele nao consegue e manter o numero.
DECLARE @num_throw INTEGER = 0, @num_raise INTEGER = 0, @msg_raise NVARCHAR(400) = '';

BEGIN TRY
    THROW 50002, 'mensagem pronta', 1;
END TRY
BEGIN CATCH
    SET @num_throw = ERROR_NUMBER();
END CATCH

BEGIN TRY
    RAISERROR ('saldo insuficiente: %s tem %s', 16, 1, 'Ana', '734.75');
END TRY
BEGIN CATCH
    SET @num_raise = ERROR_NUMBER();
    SET @msg_raise = ERROR_MESSAGE();
END CATCH

IF @num_throw = 50002 AND @num_raise = 50000
   AND @msg_raise = 'saldo insuficiente: Ana tem 734.75'
BEGIN
    PRINT '  ok    THROW manteve 50002; RAISERROR formatou a mensagem MAS';
    PRINT '        achatou o numero em 50000 -- por isso a procedure monta a';
    PRINT '        mensagem numa variavel e usa THROW';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA THROW deu ', @num_throw, ', RAISERROR deu ',
                 @num_raise, ' com mensagem "', @msg_raise, '"');
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
-- CASO 11: a procedure NAO abre transacao -- a afirmacao da secao 4, medida.
--
-- Abre-se uma transacao, chama-se a procedure num caminho que ESTOURA, e
-- verifica-se que a transacao do chamador continua viva e commitavel. Se a
-- procedure abrisse transacao e desse rollback, @@TRANCOUNT cairia a zero.
BEGIN TRAN;
    SET @tc = @@TRANCOUNT;
    BEGIN TRY
        EXEC transferir 'Ana', 'Carla', -1.00, @saldo_novo OUTPUT;
    END TRY
    BEGIN CATCH
        SET @num = ERROR_NUMBER();
    END CATCH
    SET @depois = @@TRANCOUNT;
    -- XACT_STATE() = 1 significa viva e commitavel; -1 seria "condenada",
    -- onde so o rollback e permitido.
    DECLARE @xact INTEGER = XACT_STATE();
IF @@TRANCOUNT > 0 COMMIT;

IF @tc = 1 AND @depois = 1 AND @xact = 1 AND @num = 50003
BEGIN
    PRINT '  ok    a procedure estourou SEM tocar a transacao do chamador';
    PRINT '        (@@TRANCOUNT 1 -> 1, XACT_STATE 1 = commitavel)';
    SET @ok = @ok + 1;
END
ELSE
BEGIN
    PRINT CONCAT('  FALHA transacao do chamador: antes=', @tc, ' depois=',
                 @depois, ' XACT_STATE=', @xact, ' erro=', @num);
    SET @falhou = @falhou + 1;
END

-- ---------------------------------------------------------------------------
PRINT '';
PRINT CONCAT('  ', @ok, ' passaram, ', @falhou, ' falharam');
PRINT '';

-- Sai com erro se algo falhou, para que o `verifica.sh` veja o retorno e nao
-- precise interpretar a saida. `-b` no sqlcmd transforma isto em exit != 0.
IF @falhou > 0
    THROW 50099, 'ha testes falhando', 1;
GO
