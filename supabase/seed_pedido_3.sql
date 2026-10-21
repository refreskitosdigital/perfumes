-- =====================================================================
-- Pedido 3 (ejecutar DESPUÉS de schema.sql y seed_pedidos_1_2.sql)
-- 3 socios en partes iguales (Juan, George, Rosanny): 1/3 de la ganancia cada uno.
-- Inversión: $514 = Caja acumulada $328,33 (Juan+George) + Rosanny $100 efectivo
--            + préstamo REFRESKITO Digital $85,67 ($71 completan el tercio de Rosanny + $14,67 de diferencia)
-- Los $71 prestados a Rosanny son deuda DEL NEGOCIO (se devuelven entre los 3).
-- Fecha del pedido: 19/10/2026 (ajustable en la app).
-- =====================================================================

-- ---------- Socios (correos de acceso) ----------
insert into socios (email, nombre) values
  ('juanjmontilvat@gmail.com', 'Juan'),      -- CONFIRMAR: llegó escrito "juanjmontilvatgmail.com"
  ('georfredt2.0@gmail.com', 'George'),
  ('rosandrea010803@gmail.com', 'Rosanny')
on conflict (email) do nothing;

-- ---------- Perfumes nuevos (precio_detal vacío = la app sugiere costo + 30 %) ----------
insert into perfumes (nombre) values
  ('Ariana Grande Cloud'), ('Ariana Grande Thank U Next'), ('Bestia Negra'),
  ('Carolina Herrera 212 VIP'), ('Carolina Herrera 212 VIP Black'), ('Carolina Herrera La Vie Est Belle'),
  ('Lattafa Art of Universe'), ('Lattafa Asad Men'), ('Lattafa Mayar Lujo Premium'),
  ('Lattafa Yara Candy Fem'), ('Lattafa Yara Fem'), ('Paco Rabanne Invictus Intense'),
  ('Santal 33'), ('Valentino Born in Roma Intense'), ('Armaf Odyssey Mandarin Sky Elixir'),
  ('Ariana Grande Mod Vainilla'), ('Ariana Grande Mod Blush'), ('Victorinox'),
  ('Perry Ellis Coral'), ('Perry Ellis 360'), ('Armaf Odyssey Tyrant Men'), ('Moschino Toy Boy')
on conflict do nothing;

-- ---------- Pedido ----------
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-003', '2026-10-19', null, 0)
on conflict do nothing;

-- Aportes (1/3 cada uno). Juan y George: caja + parte del préstamo; Rosanny: $100 efectivo + $71 préstamo
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-003', 'Juan',    171.33, 1.0/3),
  ('P-003', 'George',  171.33, 1.0/3),
  ('P-003', 'Rosanny', 171.34, 1.0/3)
on conflict do nothing;

-- ---------- Compras (51 unidades · $514) ----------
insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
select 'P-003', pf.id, x.unid, x.costo
from (values
  ('Ariana Grande Cloud',2,12), ('Ariana Grande Thank U Next',2,12), ('Bestia Negra',2,12),
  ('Bharara Rose Fem Lujo Premium',1,16), ('Carolina Herrera 212 VIP',1,11), ('Carolina Herrera 212 VIP Black',1,11),
  ('Carolina Herrera Good Girl Fem',2,11), ('Carolina Herrera La Vie Est Belle',1,10), ('Lattafa Art of Universe',1,19),
  ('Lattafa Asad Men',3,12), ('Lattafa Mayar Lujo Premium',1,16), ('Lattafa Yara Candy Fem',3,12),
  ('Lattafa Yara Fem',3,12), ('Invictus Parfum Paco Rabanne',1,11), ('Paco Rabanne Invictus Intense',1,10),
  ('One Million Paco Rabanne',1,11), ('Santal 33',2,12), ('Fantasy',2,10),
  ('Valentino Born in Roma Intense',1,12), ('Armaf Odyssey Mandarin Sky Elixir',1,13),
  ('Ariana Grande Mod Vainilla',1,11), ('Ariana Grande Mod Blush',1,11), ('Victorinox',2,11),
  ('9 PM Night Out',1,13), ('Perry Ellis Coral',1,10), ('Perry Ellis 360',1,10),
  ('Armaf Odyssey Tyrant Men',1,13), ('Moschino Toy Boy',1,13),
  ('Victoria Secret Splash 250ml (variados)',10,2.5)
) as x(nombre, unid, costo)
join perfumes pf on lower(pf.nombre) = lower(x.nombre)
where not exists (select 1 from compras where pedido_codigo = 'P-003');

-- ---------- Financiamiento ----------
-- La caja acumulada ($328,33) se usa para pagar el pedido: se descuenta de cada cuenta.
insert into movimientos (fecha, cuenta, monto, nota)
select '2026-10-19', c, m, 'Pago pedido P-003 con la caja acumulada'
from (values ('binance', -45::numeric), ('efectivo', -235), ('bs', -49054.5)) v(c, m)
where not exists (select 1 from movimientos where nota = 'Pago pedido P-003 con la caja acumulada');

insert into prestamos (fecha, descripcion, prestamista, monto)
select '2026-10-19', d, 'REFRESKITO Digital', m
from (values
  ('Préstamo a Rosanny para completar su tercio del pedido P-003 (deuda del negocio)', 71::numeric),
  ('Préstamo para completar el pago del pedido P-003', 14.67)
) v(d, m)
where not exists (select 1 from prestamos where descripcion like '%P-003%');
-- Deuda total con REFRESKITO Digital: 254 + 71 + 14,67 = 339,67
