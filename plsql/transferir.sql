-- transferir.sql — a mesma procedure, em PL/SQL (Oracle Database 23ai Free).
--
-- Terceira e ultima das tres versoes. As outras estao em
-- `plpgsql/transferir.sql` e `tsql/transferir.sql`, e o `COMPARACAO.md` poe as
-- tres lado a lado.
--
-- A regra de negocio e identica nas tres. O que divergiu, em ordem de
-- gravidade:
--
-- ## 1. `SELECT INTO` ja estoura sozinho -- e o Oracle e o MAIS ESTRITO dos tres
--
-- Esta e a diferenca mais importante, e e a favor do Oracle.
--
--     Oracle      `SELECT INTO` levanta NO_DATA_FOUND e TOO_MANY_ROWS
--                 POR PADRAO. Nao ha como pedir o comportamento silencioso.
--
--     PL/pgSQL    silencioso por padrao (deixa a variavel NULL e SEGUE);
--                 estoura so com a palavra `STRICT`.
--
--     T-SQL       silencioso SEMPRE, e de duas formas: sem linha a variavel
--                 fica com o VALOR ANTERIOR (nao NULL), e com varias linhas
--                 sobra a ultima, em ordem nao garantida.
--
-- O resultado pratico: a busca de pessoa aqui tem tres linhas, no PL/pgSQL
-- tem seis (`INTO STRICT` mais o bloco `EXCEPTION`), e no T-SQL tem oito (um
-- `IF NOT EXISTS` por pessoa mais um `COUNT(*) > 1` por pessoa, tudo escrito
-- a mao). O mais estrito e o mais curto.
--
-- ## 2. `RAISE_APPLICATION_ERROR`, e a faixa de mil codigos
--
-- O Oracle reserva ao usuario de **-20000 a -20999**. Mil codigos, negativos,
-- e fora da faixa o proprio `RAISE_APPLICATION_ERROR` estoura com ORA-21000 --
-- medido no `testa.sql`, caso 9.
--
-- O mapeamento com os outros dois, que o `COMPARACAO.md` repete porque um
-- chamador que fale com os tres precisa dele:
--
--     significado              PL/pgSQL   T-SQL    PL/SQL
--     pessoa nao encontrada    QL001      50001    -20001
--     saldo insuficiente       QL002      50002    -20002
--     valor nao positivo       QL003      50003    -20003
--     origem = destino         QL004      50004    -20004
--
-- E aqui o PL/SQL ganha do T-SQL num detalhe concreto:
-- `RAISE_APPLICATION_ERROR` aceita numero E mensagem montada na mesma
-- chamada. O T-SQL obriga a escolher entre numero proprio (`THROW`) e
-- mensagem formatada (`RAISERROR`), ou a registrar a mensagem em
-- `sys.messages` com privilegio de servidor.
--
-- ## 3. `PRAGMA EXCEPTION_INIT`: o chamador trata por NOME
--
-- Nenhum dos outros dois tem equivalente. O `PRAGMA` liga um numero de erro a
-- um identificador, e o chamador escreve
--
--     EXCEPTION WHEN saldo_insuficiente THEN ...
--
-- em vez de comparar `SQLCODE = -20002`. O numero continua sendo o contrato,
-- mas ele aparece UMA vez, na declaracao, em vez de em cada ponto de
-- tratamento. E medido no caso 11.
--
-- ## 4. `%TYPE`: o tipo vem da tabela
--
-- `v_saldo pessoa.saldo_inicial%TYPE` declara a variavel com o tipo da
-- COLUNA. Se a coluna virar `DECIMAL(14,4)`, a variavel acompanha sem que
-- ninguem edite este arquivo.
--
-- O PL/pgSQL tem o mesmo recurso. O **T-SQL nao tem**: la o tipo e repetido a
-- mao, e uma mudanca de escala na coluna deixa a variavel truncando em
-- silencio.
--
-- ## 5. A transacao, e o habito que este arquivo recusa
--
-- Uma procedure PL/SQL **pode** dar `COMMIT`, e por habito historico muitas
-- dao. Esta nao da, pela mesma razao das outras duas: a transacao e do
-- chamador, e duas transferencias que precisem ser atomicas em conjunto nao
-- poderiam ser.
--
-- `PRAGMA AUTONOMOUS_TRANSACTION` daria a esta procedure uma transacao
-- propria, commitada independentemente da do chamador. Seria errado aqui, e e
-- util saber que existe: e o jeito certo de gravar auditoria que deve
-- sobreviver ao rollback da operacao auditada.
--
-- ## 6. E um comportamento do Oracle que nao tem equivalente nos outros
--
-- **Todo DDL faz COMMIT implicito.** Um `CREATE TABLE` no meio de uma
-- transacao commita o DML pendente, sem aviso. Nao e opcional e nao e
-- configuravel.
--
-- Isso nao afeta esta procedure, que nao faz DDL -- mas afeta quem a chama
-- dentro de um script que crie tabela temporaria, e e medido no caso 10
-- porque e o tipo de regra que so se aprende depois de perder dados.

CREATE OR REPLACE PROCEDURE transferir(
    p_de     IN  VARCHAR2,
    p_para   IN  VARCHAR2,
    p_valor  IN  NUMBER,
    -- `OUT` e nao `IN OUT`: o PostgreSQL exige `INOUT` por uma limitacao do
    -- `CALL`, e o Oracle nao tem essa restricao. O chamador declara a
    -- variavel e a passa; nada precisa ser inicializado.
    p_saldo_novo OUT NUMBER
) AS
    -- `%TYPE` em vez de repetir os tipos: ver secao 4 do cabecalho.
    v_id_de    pessoa.id%TYPE;
    v_id_para  pessoa.id%TYPE;
    v_saldo    pessoa.saldo_inicial%TYPE;
    v_prox_id  transacao.id%TYPE;
BEGIN
    -- Validacao do valor antes de tocar o banco, como nas outras duas.
    IF p_valor IS NULL OR p_valor <= 0 THEN
        RAISE_APPLICATION_ERROR(
            -20003,
            'valor deve ser positivo, recebido: ' || NVL(TO_CHAR(p_valor), 'NULL'));
    END IF;

    -- A busca, em TRES linhas, e sem nenhum `IF EXISTS`.
    --
    -- O `SELECT INTO` do Oracle levanta NO_DATA_FOUND e TOO_MANY_ROWS por
    -- padrao -- ver secao 1. O bloco `EXCEPTION` abaixo apenas TRADUZ esses
    -- erros para o codigo do dominio; ele nao e o que torna a verificacao
    -- possivel, ao contrario do que acontece no T-SQL.
    BEGIN
        SELECT id INTO v_id_de FROM pessoa WHERE nome = p_de;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'pessoa nao encontrada: ' || p_de);
        WHEN TOO_MANY_ROWS THEN
            RAISE_APPLICATION_ERROR(-20001, 'nome ambiguo: ' || p_de);
    END;

    BEGIN
        SELECT id INTO v_id_para FROM pessoa WHERE nome = p_para;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'pessoa nao encontrada: ' || p_para);
        WHEN TOO_MANY_ROWS THEN
            RAISE_APPLICATION_ERROR(-20001, 'nome ambiguo: ' || p_para);
    END;

    IF v_id_de = v_id_para THEN
        RAISE_APPLICATION_ERROR(
            -20004, 'origem e destino sao a mesma pessoa: ' || p_de);
    END IF;

    -- O saldo, pela mesma regra de `sql/saldo.sql`. O NVL faz o papel do
    -- COALESCE -- os dois existem no Oracle, e `COALESCE` e o do padrao;
    -- `NVL` esta aqui porque e o que se le em codigo Oracle de verdade, e
    -- este projeto e sobre ler o que existe.
    SELECT p.saldo_inicial
             + NVL((SELECT SUM(t.valor) FROM transacao t
                     WHERE t.para = p.id), 0)
             - NVL((SELECT SUM(t.valor) FROM transacao t
                     WHERE t.de = p.id), 0)
      INTO v_saldo
      FROM pessoa p
     WHERE p.id = v_id_de;

    IF v_saldo < p_valor THEN
        RAISE_APPLICATION_ERROR(
            -20002,
            'saldo insuficiente: ' || p_de || ' tem ' || TO_CHAR(v_saldo)
            || ', tentou enviar ' || TO_CHAR(p_valor));
    END IF;

    -- MAX+1 pelo mesmo motivo das outras duas: o esquema e ANSI e
    -- compartilhado com o SQLite, que nao tem sequencia.
    --
    -- Em producao seria ERRADO, e o Oracle tem a melhor alternativa dos tres:
    -- uma SEQUENCE verdadeira, que nao bloqueia e nao volta atras nem em
    -- rollback. O esquema compartilhado e que impede usar.
    SELECT NVL(MAX(id), 0) + 1 INTO v_prox_id FROM transacao;

    INSERT INTO transacao (id, de, para, valor, data)
    VALUES (v_prox_id, v_id_de, v_id_para, p_valor, TRUNC(SYSDATE));

    p_saldo_novo := v_saldo - p_valor;

    -- SEM COMMIT, de proposito -- ver secao 5 do cabecalho. A transacao fica
    -- com o chamador, e `PRAGMA AUTONOMOUS_TRANSACTION` seria o recurso para
    -- o caso oposto, que nao e este.
END;
/
