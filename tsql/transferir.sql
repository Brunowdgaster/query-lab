-- transferir.sql — a mesma procedure, em T-SQL (SQL Server).
--
-- Segunda das tres versoes. A primeira esta em `plpgsql/transferir.sql`, a
-- terceira em `plsql/transferir.sql`, e as tres estao lado a lado em
-- `COMPARACAO.md`.
--
-- A regra de negocio e identica. O que divergiu, em ordem de gravidade:
--
-- ## 1. Nao existe SQLSTATE. Existe NUMERO de erro, e a fronteira e dura.
--
-- O PL/pgSQL identifica o erro por um codigo de cinco caracteres do padrao
-- ISO (`QL002`). O T-SQL identifica por um INTEIRO:
--
--     numeros < 50000   pertencem ao SQL Server
--     numeros >= 50000  sao do usuario
--
-- O mapeamento esta no `COMPARACAO.md`, porque um chamador que fale com os
-- tres bancos precisa dele:
--
--     QL001  pessoa nao encontrada   ->  50001
--     QL002  saldo insuficiente      ->  50002
--     QL003  valor nao positivo      ->  50003
--     QL004  origem = destino        ->  50004
--
-- E aqui o SQL Server e MELHOR que o PostgreSQL, o que vale dizer porque o
-- resto deste arquivo e sobre o contrario: no PostgreSQL eu precisei MEDIR
-- que a classe `QL` estava livre, depois de descobrir que `P0001`..`P0004`
-- colidiam com codigos do proprio motor -- e que `P0004` (`assert_failure`)
-- nem era capturavel por `WHEN OTHERS`. O SQL Server torna a colisao
-- impossivel por construcao, com uma fronteira numerica.
--
-- ## 2. `THROW` ou `RAISERROR`: nao se pode ter numero E mensagem formatada
--
-- A limitacao mais concreta do T-SQL neste arquivo.
--
--   * `RAISERROR('saldo: %s', 16, 1, @v)` FORMATA a mensagem, mas o numero do
--     erro sai **50000 fixo** -- a menos que a mensagem esteja pre-registrada
--     em `sys.messages` via `sp_addmessage`, que exige privilegio de servidor
--     e deixa o codigo dependente do estado da instalacao;
--   * `THROW 50002, 'mensagem', 1` respeita o numero, mas **nao formata
--     nada**: o segundo argumento tem de ser uma string ja pronta.
--
-- A saida e montar a mensagem numa variavel e dar `THROW` nela. E por isso
-- que cada erro aqui tem duas linhas onde o PL/pgSQL tem uma.
--
-- O PL/pgSQL tem os dois de uma vez (`RAISE ... USING ERRCODE`), e o PL/SQL
-- tambem (`RAISE_APPLICATION_ERROR` aceita numero e mensagem montada). O
-- T-SQL e o unico dos tres que obriga a contornar.
--
-- ## 3. Nao existe `SELECT INTO STRICT`, e o silencio e DUPLO
--
-- O PL/pgSQL tem `SELECT ... INTO STRICT`, que transforma "nao achou" e
-- "achou demais" em excecao. O T-SQL nao tem equivalente, e as duas falhas
-- sao silenciosas de formas diferentes:
--
--   * **nao achou**: `SELECT @v = id FROM pessoa WHERE nome = 'ninguem'`
--     deixa `@v` **com o valor anterior**, nao com NULL. Se a variavel foi
--     usada antes, o codigo segue com o id ERRADO, e nao com nulo. Isto e
--     medido no `testa.sql`, caso 8, porque e contraintuitivo o suficiente
--     para merecer evidencia em vez de afirmacao;
--   * **achou demais**: a atribuicao e feita linha a linha e sobra a ULTIMA,
--     em ordem nao garantida. Nenhum aviso.
--
-- Por isso cada busca aqui e `IF NOT EXISTS` seguida de atribuicao, e nao uma
-- atribuicao confiando no resultado. E mais verboso, e e a unica forma
-- correta.
--
-- ## 4. A transacao: esta procedure NAO abre transacao, e o motivo e T-SQL
--
-- No PL/pgSQL a decisao foi "nao dar COMMIT, deixar a transacao com o
-- chamador". No T-SQL a mesma decisao tem razao mais forte, e e a semantica
-- de aninhamento:
--
--     `BEGIN TRAN` dentro de outra transacao NAO cria transacao aninhada:
--     apenas incrementa `@@TRANCOUNT`. E um `ROLLBACK` -- um so -- desfaz
--     TODOS os niveis e zera `@@TRANCOUNT`.
--
-- Ou seja: se esta procedure abrisse `BEGIN TRAN` e desse `ROLLBACK` ao
-- detectar saldo insuficiente, ela destruiria a transacao do CHAMADOR, junto
-- com tudo que ele ja tinha feito antes de chamar. O chamador nao tem como se
-- defender, e nao recebe aviso.
--
-- `SAVE TRANSACTION` seria o contorno, e tem um porem proprio: nao funciona
-- se a transacao estiver em estado **nao-commitavel** (`XACT_STATE() = -1`),
-- que e onde certos erros a colocam. O `testa.sql` mede os dois.
--
-- A escolha deste arquivo e nao abrir transacao nenhuma: validar tudo ANTES
-- de escrever, e escrever uma unica linha. Com uma unica instrucao de escrita
-- a atomicidade e a do proprio comando, e nao ha nada a desfazer.
--
-- ## 5. Devolver valor: `OUTPUT`
--
-- Parecido com o `INOUT` do PostgreSQL, com uma diferenca a favor do T-SQL:
-- aqui o parametro de saida exige variavel no chamador SEMPRE, nos dois
-- contextos. No PL/pgSQL, `CALL ... NULL` e aceito direto do psql e recusado
-- de dentro de um bloco -- o mesmo comando e valido num contexto e invalido
-- no outro. Essa assimetria esta documentada em `plpgsql/testa.sql`.

IF OBJECT_ID('transferir', 'P') IS NOT NULL
    DROP PROCEDURE transferir;
GO

CREATE PROCEDURE transferir
    @p_de    VARCHAR(40),
    @p_para  VARCHAR(40),
    @p_valor DECIMAL(12,2),
    @p_saldo_novo DECIMAL(12,2) OUTPUT
AS
BEGIN
    -- SET NOCOUNT ON suprime as linhas "(1 row affected)".
    --
    -- Nao e cosmetico: sem ele, um cliente que leia o resultado da chamada
    -- recebe contagens antes do que pediu, e biblioteca que espera um
    -- resultado unico quebra. E o primeiro item de qualquer revisao de
    -- procedure em T-SQL.
    SET NOCOUNT ON;

    DECLARE @v_id_de   INTEGER,
            @v_id_para INTEGER,
            @v_saldo   DECIMAL(12,2),
            @v_prox_id INTEGER,
            @msg       NVARCHAR(400);

    -- Validacao do valor antes de tocar o banco, como nas outras duas: e a
    -- mais barata, e falhar cedo deixa a mensagem mais especifica.
    IF @p_valor IS NULL OR @p_valor <= 0
    BEGIN
        -- As duas linhas que a secao 2 explica: montar a mensagem, depois
        -- lancar.
        --
        -- `CONCAT` e nao `+` porque `+` com NULL da NULL, e @p_valor pode ser
        -- NULL exatamente neste caminho: a mensagem sumiria justamente no
        -- caso que ela existe para descrever. `CONCAT` trata NULL como vazio,
        -- e o `ISNULL` explicito deixa a palavra "NULL" na mensagem.
        SET @msg = CONCAT('valor deve ser positivo, recebido: ',
                          ISNULL(CONVERT(VARCHAR(40), @p_valor), 'NULL'));
        THROW 50003, @msg, 1;
    END

    -- `IF NOT EXISTS` e nao atribuicao direta, pelo motivo da secao 3: uma
    -- atribuicao que nao acha nada deixa a variavel INTOCADA, e seguir com id
    -- errado e pior que seguir com nulo.
    IF NOT EXISTS (SELECT 1 FROM pessoa WHERE nome = @p_de)
    BEGIN
        SET @msg = CONCAT('pessoa nao encontrada: ', @p_de);
        THROW 50001, @msg, 1;
    END

    IF NOT EXISTS (SELECT 1 FROM pessoa WHERE nome = @p_para)
    BEGIN
        SET @msg = CONCAT('pessoa nao encontrada: ', @p_para);
        THROW 50001, @msg, 1;
    END

    -- O caso "achou demais" tambem e silencioso. O dominio garante nome
    -- unico, mas garantir no dominio nao e verificar no codigo -- e o
    -- PL/pgSQL recebe esta verificacao de graca com `STRICT`, enquanto aqui
    -- ela custa duas consultas escritas a mao.
    IF (SELECT COUNT(*) FROM pessoa WHERE nome = @p_de) > 1
       OR (SELECT COUNT(*) FROM pessoa WHERE nome = @p_para) > 1
    BEGIN
        SET @msg = 'nome ambiguo';
        THROW 50001, @msg, 1;
    END

    SELECT @v_id_de = id FROM pessoa WHERE nome = @p_de;
    SELECT @v_id_para = id FROM pessoa WHERE nome = @p_para;

    IF @v_id_de = @v_id_para
    BEGIN
        SET @msg = CONCAT('origem e destino sao a mesma pessoa: ', @p_de);
        THROW 50004, @msg, 1;
    END

    -- O saldo, pela mesma regra de `sql/saldo.sql`. O COALESCE existe pelo
    -- mesmo motivo nos tres dialetos: quem nunca transacionou tem SUM() nulo,
    -- e `NULL < valor` nao e falso, e desconhecido -- o IF nao entraria, e a
    -- transferencia passaria sem saldo nenhum.
    SELECT @v_saldo = p.saldo_inicial
             + COALESCE((SELECT SUM(t.valor) FROM transacao t
                          WHERE t.para = p.id), 0)
             - COALESCE((SELECT SUM(t.valor) FROM transacao t
                          WHERE t.de = p.id), 0)
      FROM pessoa p
     WHERE p.id = @v_id_de;

    IF @v_saldo < @p_valor
    BEGIN
        SET @msg = CONCAT('saldo insuficiente: ', @p_de, ' tem ',
                          CONVERT(VARCHAR(40), @v_saldo),
                          ', tentou enviar ', CONVERT(VARCHAR(40), @p_valor));
        THROW 50002, @msg, 1;
    END

    -- MAX+1 pelo mesmo motivo das outras duas: o esquema e ANSI e
    -- compartilhado com o SQLite, que nao tem sequencia.
    --
    -- Em producao isto seria ERRADO, e no SQL Server e errado de um jeito
    -- proprio: sem `HOLDLOCK`, duas sessoes leem o mesmo MAX e colidem na
    -- PRIMARY KEY. O comentario existe para que ninguem copie como padrao. O
    -- SQL Server teria `IDENTITY` ou `SEQUENCE`; e o esquema ANSI
    -- compartilhado que impede usar.
    SELECT @v_prox_id = COALESCE(MAX(id), 0) + 1 FROM transacao;

    INSERT INTO transacao (id, de, para, valor, data)
    VALUES (@v_prox_id, @v_id_de, @v_id_para, @p_valor,
            CAST(GETDATE() AS DATE));

    SET @p_saldo_novo = @v_saldo - @p_valor;

    -- SEM transacao e SEM commit, de proposito -- ver secao 4 do cabecalho.
    -- Uma unica instrucao de escrita e atomica por si, e abrir `BEGIN TRAN`
    -- aqui daria a esta procedure o poder de destruir a transacao do chamador
    -- com um `ROLLBACK`.
END
GO
