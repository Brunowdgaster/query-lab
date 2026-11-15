-- carga.sql — popula o esquema a partir dos CSV.
--
-- Como INSERT literal, e não `.import` do SQLite ou `COPY` do Postgres: os
-- dois são comandos de FERRAMENTA, não de linguagem, e divergem. O projeto
-- compara modelos de dados, então a carga tem de ser a mesma nos dois.
--
-- A amizade entra na forma canônica (a < b), que é o CHECK do esquema. O CSV
-- já está nessa forma; se não estivesse, a carga falharia -- e falhar é o
-- comportamento certo, porque (2,1) e (1,2) coexistindo contariam o mesmo
-- amigo duas vezes.

-- O saldo inicial de 1000 em todos: numero redondo para a aritmetica da
-- procedure ser conferivel de cabeca. Ana envia 195,25 e recebe 30,00, entao
-- o saldo dela e 834,75 -- e o teste de "saldo insuficiente" pede 2000.
INSERT INTO pessoa (id, nome, cidade, saldo_inicial) VALUES
  (1,'Ana','Recife',1000.00), (2,'Bruno','Recife',1000.00),
  (3,'Carla','Olinda',1000.00), (4,'Diego','Recife',1000.00),
  (5,'Elisa','Olinda',1000.00), (6,'Fabio','Jaboatao',1000.00),
  (7,'Gabi','Recife',1000.00), (8,'Hugo','Jaboatao',1000.00),
  (9,'Iris','Olinda',1000.00), (10,'Joao','Recife',1000.00),
  (11,'Kelly','Caruaru',1000.00), (12,'Lucas','Caruaru',1000.00);

INSERT INTO amizade (a, b) VALUES
  (1,2), (1,3), (2,4), (3,5), (4,6), (5,6), (6,7), (7,8), (8,9),
  (10,11), (11,12);

INSERT INTO transacao (id, de, para, valor, data) VALUES
  (1, 1, 2, 150.00, '2026-01-10'),
  (2, 2, 4,  80.50, '2026-01-11'),
  (3, 4, 6, 220.00, '2026-01-12'),
  (4, 1, 3,  45.25, '2026-01-13'),
  (5, 3, 5, 310.00, '2026-01-14'),
  (6, 6, 7,  95.00, '2026-01-15'),
  (7, 7, 8,  60.00, '2026-01-16'),
  (8,10,11, 500.00, '2026-01-17'),
  (9,11,12,  25.75, '2026-01-18'),
  (10,2, 1,  30.00, '2026-01-19');
