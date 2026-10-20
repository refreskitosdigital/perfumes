-- =====================================================================
-- DATOS REALES: Pedidos 1 y 2 (ejecutar DESPUÉS de schema.sql)
-- Ambos pedidos: Juan 50 % · George 50 %. Rosanny entra desde el pedido 3.
-- Fechas de ventas: se usó la fecha de cada compra (07/10 y 16/10) porque no se
-- indicó la fecha exacta; se pueden corregir en la app.
-- =====================================================================

insert into tasas (fecha, bcv, binance) values
  ('2026-10-07', 876.79, 1015),
  ('2026-10-16', 881, 1015)       -- Binance del 16/10 asumido (1015): corregir en Tasas si fue otro
on conflict (fecha) do nothing;

-- ---------- Perfumes (nombre, precio de venta al detal) ----------
insert into perfumes (nombre, precio_detal) values
  ('La Bomba Carolina Herrera', 40), ('Meow Katy Perry', 25), ('Valentino Donna Intense', 38),
  ('Invictus Parfum Paco Rabanne', 40), ('Set de regalo Odyssey Collection', 45), ('Fantasy', 25),
  ('9 PM Night Out', 35),
  ('Paris Hilton Can Can', 35), ('Afnan 9am Femme', 25), ('Carolina Herrera Bad Boy', 30),
  ('Armaf Beach Party', null), ('Carolina Herrera 212 VIP Fem', 30), ('Orientica Amber Rouge', 35),
  ('Lattafa Khamrah Karaz Unisex Lujo Premium', 40), ('One Million Paco Rabanne', null),
  ('Mont Blanc Starwalker Men', 35), ('Lacoste White Men', 30), ('Armaf Odyssey Mega Men', 30),
  ('Bharara Rose Fem Lujo Premium', 30), ('Victoria Secret Splash 250ml (variados)', 10),
  ('Carolina Herrera Good Girl Fem', 35), ('Giorgio Armani Acqua di Gio Men', 25)
on conflict do nothing;

-- ---------- Pedido 1 · 07/10 · $125 mercancía + $20 envío ----------
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-001', '2026-10-07', null, 20)
on conflict do nothing;
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-001', 'Juan', 72.5, 0.5), ('P-001', 'George', 72.5, 0.5) on conflict do nothing;

-- ---------- Pedido 2 · 16/10 · comprado en Caracas, sin envío ----------
-- Las 8 fragancias de splash se cargan como un solo producto: 16 unidades a $3 (factura: $6 por par)
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-002', '2026-10-16', 'Proveedor en Caracas', 0)
on conflict do nothing;
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-002', 'Juan', 127, 0.5), ('P-002', 'George', 127, 0.5) on conflict do nothing;

insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
select x.pedido, pf.id, x.unid, x.costo
from (values
  ('P-001','La Bomba Carolina Herrera',1,22), ('P-001','Meow Katy Perry',1,15),
  ('P-001','Valentino Donna Intense',1,15), ('P-001','Invictus Parfum Paco Rabanne',1,17),
  ('P-001','Set de regalo Odyssey Collection',1,23), ('P-001','Fantasy',1,15), ('P-001','9 PM Night Out',1,18),
  ('P-002','Paris Hilton Can Can',1,12), ('P-002','Afnan 9am Femme',1,13), ('P-002','Carolina Herrera Bad Boy',1,13),
  ('P-002','Armaf Beach Party',1,14), ('P-002','Carolina Herrera 212 VIP Fem',1,13), ('P-002','Orientica Amber Rouge',1,14),
  ('P-002','Lattafa Khamrah Karaz Unisex Lujo Premium',1,18), ('P-002','Invictus Parfum Paco Rabanne',1,13),
  ('P-002','One Million Paco Rabanne',1,13), ('P-002','Mont Blanc Starwalker Men',1,13), ('P-002','Lacoste White Men',1,12),
  ('P-002','Armaf Odyssey Mega Men',1,15), ('P-002','Bharara Rose Fem Lujo Premium',1,18),
  ('P-002','Victoria Secret Splash 250ml (variados)',16,3),
  ('P-002','Carolina Herrera Good Girl Fem',1,13), ('P-002','Giorgio Armani Acqua di Gio Men',1,12)
) as x(pedido, nombre, unid, costo)
join perfumes pf on lower(pf.nombre) = lower(x.nombre)
where not exists (select 1 from compras);

-- ---------- Ventas ----------
create temp table _v (
  fecha date, cliente text, vendedor text, nombre text, pedido text, unid int, precio numeric,
  base text, bcv numeric, bin numeric, vence date, nota text
);
insert into _v values
 -- Pedido 1
 ('2026-10-07','Maria Fernanda','Juan','La Bomba Carolina Herrera','P-001',1,40,'divisa',876.79,1015,'2026-10-30',null),
 ('2026-10-07','Mildred Ramos','Juan','Meow Katy Perry','P-001',1,22.5,'divisa',876.79,1015,null,'Combo Meow + Fantasy $45'),
 ('2026-10-07','Mildred Ramos','Juan','Fantasy','P-001',1,22.5,'divisa',876.79,1015,null,'Combo Meow + Fantasy $45'),
 ('2026-10-07','Neysimar','Juan','Valentino Donna Intense','P-001',1,38,'bcv',876.79,1015,'2026-10-30','Pagará en Bs'),
 ('2026-10-07','Eduin Torres','Juan','9 PM Night Out','P-001',1,35,'divisa',876.79,1015,'2026-10-30',null),
 ('2026-10-07','Ender Barbero','George','Set de regalo Odyssey Collection','P-001',1,45,'divisa',876.79,1015,null,null),
 ('2026-10-07','Ender Barbero','George','Invictus Parfum Paco Rabanne','P-001',1,40,'divisa',876.79,1015,null,null),
 -- Pedido 2
 ('2026-10-16','Albany Rebolledo','Juan','Paris Hilton Can Can','P-002',1,35,'bcv',881,1015,'2026-10-30','A tasa BCV'),
 ('2026-10-16','Luisa Teran','Juan','Afnan 9am Femme','P-002',1,25,'divisa',881,1015,'2026-10-30','Con 2 splash: total $40'),
 ('2026-10-16','Luisa Teran','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30','Con Afnan: total $40'),
 ('2026-10-16','Carlos Zuniga','Juan','Carolina Herrera Bad Boy','P-002',1,30,'divisa',881,1015,null,null),
 ('2026-10-16','Juan Montilva','Juan','Armaf Beach Party','P-002',1,20,'divisa',881,1015,null,null),
 ('2026-10-16','Rosalia Torres','Juan','Carolina Herrera 212 VIP Fem','P-002',1,30,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Maria Fernanda','Juan','Orientica Amber Rouge','P-002',1,35,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jesus Teran','Juan','Lattafa Khamrah Karaz Unisex Lujo Premium','P-002',1,40,'divisa',881,1015,'2026-10-30','Pagó $20, debe $20'),
 ('2026-10-16','George','George','Invictus Parfum Paco Rabanne','P-002',1,40,'divisa',881,1015,null,null),
 ('2026-10-16','Wuile Kyomu','Juan','Mont Blanc Starwalker Men','P-002',1,35,'divisa',881,1015,'2026-10-30','Pagó $20, debe $15'),
 ('2026-10-16','Kyuran','Juan','Lacoste White Men','P-002',1,30,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jean Mary de la Hoz','George','Armaf Odyssey Mega Men','P-002',1,30,'divisa',881,1015,'2026-10-30','Pagará $60 por Binance por ambos perfumes'),
 ('2026-10-16','Jean Mary de la Hoz','George','Bharara Rose Fem Lujo Premium','P-002',1,30,'divisa',881,1015,'2026-10-30','Pagará $60 por Binance por ambos perfumes'),
 ('2026-10-16','Doris Teran','Juan','Carolina Herrera Good Girl Fem','P-002',1,35,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jose Montilva','Juan','Giorgio Armani Acqua di Gio Men','P-002',1,25,'divisa',881,1015,'2026-10-30',null),
 -- Splash
 ('2026-10-16','Gina Pena','Juan','Victoria Secret Splash 250ml (variados)','P-002',4,9,'bcv',881,1015,'2026-10-30','Pagó $18 en Bs a 881, debe $18'),
 ('2026-10-16','Anny Guitian','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Rosanny Cequea','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30','Socia a partir del pedido 3'),
 ('2026-10-16','Fabian Gago','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'bcv',881,1015,'2026-10-30','Pagó $7,50 en Bs a 881, debe $7,50'),
 ('2026-10-16','Lori Teran','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,985,null,'Pagó en Bs a tasa 985'),
 ('2026-10-16','Maria Fernanda','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Wuile Kyomu','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,7,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Kyuran','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,1015,'2026-10-30','Con Lacoste'),
 -- Venta anticipada: aún no se compra el perfume (entra en el pedido 3)
 ('2026-10-16','Rosangela Cequea','Juan','Valentino Donna Intense',null,1,38,'bcv',881,1015,null,'Prepagó $19 a BCV. Hay que comprar el perfume (pedido 3) y asignarle el pedido');

insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
select v.fecha, v.cliente, v.vendedor, pf.id, v.pedido, v.unid, v.precio, v.base, v.bcv, v.bin, v.vence, v.nota
from _v v join perfumes pf on lower(pf.nombre) = lower(v.nombre)
where not exists (select 1 from ventas);

-- ---------- Cobros ya recibidos ----------
create temp table _c (cliente text, nombre text, cuenta text, monto numeric);
insert into _c values
 ('Mildred Ramos','Meow Katy Perry','binance',22.5), ('Mildred Ramos','Fantasy','binance',22.5),
 ('Eduin Torres','9 PM Night Out','efectivo',20),
 ('Ender Barbero','Set de regalo Odyssey Collection','efectivo',45),
 ('Ender Barbero','Invictus Parfum Paco Rabanne','efectivo',40),
 ('Carlos Zuniga','Carolina Herrera Bad Boy','efectivo',30),
 ('Juan Montilva','Armaf Beach Party','efectivo',20),
 ('Jesus Teran','Lattafa Khamrah Karaz Unisex Lujo Premium','efectivo',20),
 ('George','Invictus Parfum Paco Rabanne','efectivo',40),
 ('Wuile Kyomu','Mont Blanc Starwalker Men','efectivo',20),
 ('Gina Pena','Victoria Secret Splash 250ml (variados)','bs',15858),      -- $18 × 881
 ('Fabian Gago','Victoria Secret Splash 250ml (variados)','bs',6607.5),   -- $7,50 × 881
 ('Lori Teran','Victoria Secret Splash 250ml (variados)','bs',9850),      -- $10 × 985
 ('Rosangela Cequea','Valentino Donna Intense','bs',16739);              -- $19 × 881

insert into cobros (venta_id, fecha, cuenta, monto)
select v.id, v.fecha, c.cuenta, c.monto
from _c c
join perfumes pf on lower(pf.nombre) = lower(c.nombre)
join ventas v on v.cliente = c.cliente and v.perfume_id = pf.id
where not exists (select 1 from cobros);

-- ---------- Préstamo para pagar el pedido 2 ----------
insert into prestamos (fecha, descripcion, prestamista, monto)
select '2026-10-16', 'Préstamo para pagar el pedido P-002 (se devuelve con las ventas)', 'REFRESKITO Digital', 254
where not exists (select 1 from prestamos);

-- =====================================================================
-- SOCIOS (ejecutar aparte, con los correos reales)
-- =====================================================================
-- insert into socios (email, nombre) values
--   ('correo.de.juan@gmail.com', 'Juan'),
--   ('correo.de.george@gmail.com', 'George'),
--   ('correo.de.rosanny@gmail.com', 'Rosanny');   -- puede agregarse al crear el pedido 3
