-- =====================================================================
-- MIGRACIÓN v16 · REEMPLAZO de todas las ventas y cobros con la información correcta (lotes 1 a 4)
-- Ejecutar DESPUÉS de migracion_v14.sql (la v15 NO hace falta; si ya la corriste, esta la limpia).
-- ANTES: guarda un respaldo desde la app (Respaldo) y guarda hoy las tasas (Tasa del día).
--
-- QUÉ HACE
--  1. Borra TODAS las ventas y cobros actuales, las compras de divisa y los ajustes de caja de la v15.
--  2. Carga las 69 ventas de los lotes 1 a 4 con sus cobros (fecha, cuenta, monto y tasa de cada pago).
--  3. NO toca pedidos, compras, aportes de los socios, préstamos ni gastos (taxi $11 y arroz chino $20 se mantienen).
--  4. Registra la pérdida del Yara Candy defectuoso: 1 unidad menos en el P-003 y gasto operativo de $12 (sin tocar la caja).
--  5. Cuadra la caja con lo que hay a la mano: efectivo $67, Binance $76 y banco 2.600 Bs.
--     El dinero que sobra respecto a las ventas registradas queda como un INCISO aparte
--     ("Sobrante por conciliar"): está dentro del saldo real pero separado de lo que explican las ventas.
-- Se aplica UNA sola vez: si repites el archivo no duplica nada.
-- =====================================================================
alter table movimientos add column if not exists concilia boolean not null default false;

create or replace function norm_txt(t text) returns text language sql immutable as $f$
  select regexp_replace(translate(lower(coalesce(t, '')), 'áéíóúüñôèêàâ', 'aeiouunoeeaa'), '[^a-z0-9]+', '', 'g')
$f$;

do $$
declare
  r record; v_id bigint; f date; tb numeric; tcv numeric;
  falta text;
  t_ef constant numeric := 67; t_bin constant numeric := 76; t_bs constant numeric := 2600;
  s_ef numeric; s_bin numeric; s_bs numeric; bs_conv numeric; div numeric; pe numeric; pb numeric; tot numeric;
  a_e numeric; a_b numeric; bs_e numeric; bs_b numeric; delta numeric; cta text;
begin
  if exists (select 1 from cargas_hechas where clave = 'v16_reemplazo_ventas') then
    raise notice 'La v16 ya estaba aplicada. No se repite.'; return;
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'cobros' and column_name = 'tasa_bcv') then
    raise exception 'Primero ejecuta migracion_v14.sql.';
  end if;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  drop table if exists _v16_v, _v16_c, _v16_p, _v16_old, _v16_id;
  -- ---------- Datos: ventas (n, lote, cliente, vendedor, perfume, unidades, total $, base, vence) ----------
  create temp table _v16_v (n int, ped text, cliente text, vend text, perfume text, unid int, total numeric, base text, vence date) on commit drop;
  insert into _v16_v values
   (1,'P-001','María Fernanda Kyomu','Juan','La Bomba Carolina Herrera',1,35,'divisa',null),
   (2,'P-001','Mildred Ramos','Juan','Meow Katy Perry',1,25,'divisa',null),
   (3,'P-001','Neysimar','Juan','Valentino Donna Intense',1,35,'divisa','2026-11-15'),
   (4,'P-001','Ender Barbero','George','Invictus Parfum Paco Rabanne',1,40,'divisa',null),
   (5,'P-001','Ender Barbero','George','Set de regalo Odyssey Collection',1,45,'divisa',null),
   (6,'P-001','Mildred Ramos','Juan','Fantasy',1,25,'divisa',null),
   (7,'P-001','Eduin Torres','Juan','9 PM Night Out',1,35,'divisa',null),
   (8,'P-002','Albany Rebolledo','Juan','Paris Hilton Can Can',1,35,'divisa',null),
   (9,'P-002','Luisa Teran','Juan','Afnan 9am Femme',1,25,'divisa',null),
   (10,'P-002','Carlos Zuñiga','Juan','Carolina Herrera Bad Boy',1,30,'divisa',null),
   (11,'P-002','Juan Montilva','Juan','Armaf Beach Party',1,20,'divisa',null),
   (12,'P-002','Rosalia Torres','Juan','Carolina Herrera 212 VIP Fem',1,30,'divisa',null),
   (13,'P-002','María Fernanda Kyomu','Juan','Orientica Amber Rouge',1,35,'divisa',null),
   (14,'P-002','Jesus Teran','Juan','Lattafa Khamrah Karaz Unisex Lujo Premium',1,40,'divisa',null),
   (15,'P-002','Jesus Teran','Juan','One Million Paco Rabanne',1,20,'divisa',null),
   (16,'P-002','Wuile Kyomu','Juan','Mont Blanc Starwalker Men',1,35,'divisa','2026-11-02'),
   (17,'P-002','Kyuran','Juan','Lacoste White Men',1,30,'divisa',null),
   (18,'P-002','Jean Mary de la Hoz','George','Armaf Odyssey Mega Men',1,30,'divisa',null),
   (19,'P-002','Jean Mary de la Hoz','George','Bharara Rose Fem Lujo Premium',1,30,'divisa',null),
   (20,'P-002','Doris Teran','Juan','Carolina Herrera Good Girl Fem',1,35,'divisa',null),
   (21,'P-002','José Montilva','Juan','Giorgio Armani Acqua di Gio Men',1,25,'divisa',null),
   (22,'P-002','Juan Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (23,'P-002','Dra. Yexi','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (24,'P-002','Luisa Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (25,'P-002','Kyuran','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (26,'P-002','Wuile Kyomu','Juan','Victoria Secret Splash 250ml (variados)',1,7,'divisa',null),
   (27,'P-002','María Fernanda Kyomu','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (28,'P-002','Lori Teran','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (29,'P-002','Fabian Gago','Juan','Victoria Secret Splash 250ml (variados)',2,15,'bcv',null),
   (30,'P-002','Rosanny Cequea','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (31,'P-002','Anny Guitian','Juan','Victoria Secret Splash 250ml (variados)',2,15,'bcv',null),
   (32,'P-003','Lori Teran','Juan','Ariana Grande Cloud',1,25,'divisa',null),
   (33,'P-003','Keylin Cabrera','Juan','Ariana Grande Thank U Next',1,25,'divisa',null),
   (34,'P-003','Anny Guitian','Juan','Ariana Grande Thank U Next',1,35,'bcv',null),
   (35,'P-003','Jesus Teran','Juan','Bestia Negra',1,20,'divisa',null),
   (36,'P-003','Wuile Kyomu','Juan','Bestia Negra',1,30,'divisa',null),
   (37,'P-003','Almari','Juan','Bharara Rose Fem Lujo Premium',1,45,'bcv',null),
   (38,'P-003','Rosalba Guitian','Rosanny','Carolina Herrera Good Girl Fem',1,30,'divisa',null),
   (39,'P-003','Rosalba Montilva','Juan','Lancôme La Vie Est Belle',1,25,'divisa',null),
   (40,'P-003','Andreina (esposa de Ismael)','Wuilesmar','Lattafa Yara Clásico',1,25,'bcv',null),
   (41,'P-003','Jessica Green Hair','George','Lattafa Yara Candy Fem',1,30,'bcv','2026-11-17'),
   (42,'P-003','Jhoany Guitian','Rosanny','Lattafa Yara Candy Fem',1,35,'bcv',null),
   (44,'P-003','Jema de La Hoz','George','Paco Rabanne One Million Lucky',1,30,'divisa','2026-11-15'),
   (45,'P-003','Doris Teran','Juan','Fantasy',1,25,'divisa','2026-11-15'),
   (46,'P-003','Juan Perez','Juan','Armaf Odyssey Mandarin Sky Elixir',1,35,'divisa',null),
   (47,'P-003','Carola Carvajal','George','Armaf Odyssey Mandarin Sky Elixir',1,30,'divisa',null),
   (48,'P-003','Lori Teran','Juan','Ariana Grande Mod Blush',1,25,'divisa',null),
   (49,'P-003','Elvys Castillo','Juan','Victorinox Swiss Army Classic',1,25,'divisa',null),
   (50,'P-003','Jefren Carpintero','Jose Montilva','9 PM Night Out',1,35,'bcv',null),
   (51,'P-003','Juan Teran','Juan','9 PM Night Out',1,35,'divisa',null),
   (52,'P-003','Rosangela Cequea','Juan','Valentino Donna Fem',1,38,'bcv',null),
   (53,'P-003','Gina Pena','Rosanny','Victoria Secret Splash 250ml (variados)',4,36,'bcv',null),
   (54,'P-003','Doris Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa','2026-11-15'),
   (55,'P-003','Veronica','Gardimar','Carolina Herrera 212 VIP Rose Fem',1,25,'divisa',null),
   (56,'P-003','Carpintero','Jose Montilva','Bharara Viking Kashmir Lujo',1,45,'divisa',null),
   (57,'P-003','Carola Carvajal','George','Lattafa Yara Tous Fem',1,30,'divisa',null),
   (58,'P-003','Hijo del Carpintero','Jose Montilva','Afnan 9am Dive Unisex',1,35,'bcv','2026-11-15'),
   (59,'P-004','Jessica Green Hair','George','Bestia Negra',1,30,'divisa','2026-11-17'),
   (60,'P-004','Mauricio Garces','Juan','Mont Blanc Legend Spirit',1,25,'divisa',null),
   (61,'P-004','Cliente de Wuile (sin nombre)','Wuilesmar','Victoria Secret Splash 250ml (variados)',1,7,'divisa',null),
   (62,'P-004','Yeimy Green Hair','George','Bharara Rose Fem Lujo Premium',1,30,'divisa','2026-11-17'),
   (63,'P-004','Yeimy Green Hair','George','Lattafa Khamrah Karaz Unisex Lujo Premium',1,30,'divisa','2026-11-17'),
   (64,'P-004','Ariana Marquez','Juan','Carolina Herrera Good Girl Fem',1,35,'divisa','2026-11-30'),
   (65,'P-004','Veronica','Gardimar','9 PM Night Out',1,35,'divisa',null),
   (66,'P-004','Jean Mary de la Hoz','George','Armaf Odyssey Mandarin Sky',1,30,'divisa','2026-11-15'),
   (67,'P-004','Jesus Zapatero','Wuilesmar','Armaf Odyssey Mandarin Sky Elixir',1,25,'divisa',null),
   (68,'P-004','Rosanna Aqua Vic','Juan','Ariana Grande Mod Blush',1,35,'divisa','2026-11-02'),
   (69,'P-004','Felix Aqua Vic','Juan','Bharara Kinh Soleil Lujo Premium',1,40,'divisa','2026-11-15'),
   (70,'P-004','Adriana Aqua Vic','Juan','Armaf Odyssey Pink Pop Fem',1,35,'divisa',null);

  -- ---------- Datos: cobros (n de la venta, fecha, cuenta, monto, tasa BCV/Binance a la que pagó si es en Bs) ----------
  create temp table _v16_c (n int, fecha date, cuenta text, monto numeric, tasa numeric) on commit drop;
  insert into _v16_c values
   (2,null,'binance',25,null), (3,'2026-11-01','bs',14985,993),
   (4,'2026-10-15','bs',40000,1000), (5,'2026-10-15','bs',45000,1000), (6,null,'binance',25,null),
   (7,'2026-10-15','bs',20600,1030), (7,'2026-10-30','bs',14910,994),
   (8,'2026-10-30','bs',15561.97,889.25), (9,'2026-10-15','efectivo',25,null), (10,'2026-10-16','bs',30000,1000),
   (11,'2026-10-16','efectivo',20,null), (14,'2026-10-30','efectivo',40,null), (16,'2026-10-15','bs',19600,980),
   (20,'2026-10-30','efectivo',35,null), (21,null,'efectivo',20,null),
   (22,'2026-10-26','bs',15000,1000), (26,'2026-10-30','bs',6952,993.142857), (28,'2026-10-17','bs',9857.30,985.73),
   (29,'2026-10-15','bs',6607.95,881.06), (29,'2026-10-30','bs',6667.5,889),
   (31,'2026-10-26','bs',6660,886), (31,'2026-10-30','bs',6667.5,888),
   (32,'2026-10-29','bs',24734.72,989.3888), (33,'2026-10-23','efectivo',25,null), (37,'2026-10-30','bs',20002.5,889),
   (40,'2026-10-30','bs',16878,991), (46,'2026-10-30','efectivo',20,null), (50,'2026-10-26','bs',31080,888),
   (52,'2026-10-16','bs',16772.2,882.7), (53,'2026-10-26','bs',15984,888), (58,'2026-10-30','bs',17760,888),
   (60,'2026-10-22','bs',9930,993), (69,'2026-10-30','efectivo',20,null), (70,'2026-10-30','binance',35,null);

  -- ---------- Los perfumes deben existir (si falta alguno, no se toca nada) ----------
  create temp table _v16_p on commit drop as
    select distinct x.perfume, (select pf.id from perfumes pf where norm_txt(pf.nombre) = norm_txt(x.perfume) order by pf.id limit 1) as pid
    from _v16_v x;
  select string_agg(perfume, ', ') into falta from _v16_p where pid is null;
  if falta is not null then raise exception 'No se encontraron estos perfumes y no se aplicó nada: %', falta; end if;

  -- ---------- Se conservan las fechas de venta que ya estaban cuando se puede ----------
  create temp table _v16_old on commit drop as
    select perfume_id, pedido_codigo, lower(cliente) as cli, min(fecha) as fecha from ventas group by 1, 2, 3;

  -- ---------- Se borra lo anterior ----------
  delete from conversiones;
  delete from movimientos where concilia or nota like 'Ajuste al conteo real%';
  delete from ventas;   -- los cobros se borran con ellas

  -- ---------- Se cargan las ventas ----------
  create temp table _v16_id (n int, id bigint) on commit drop;
  for r in select x.*, p.pid, pe.fecha as fped,
                  (select min(c.fecha) from _v16_c c where c.n = x.n and c.fecha is not null) as fcob
           from _v16_v x join _v16_p p on p.perfume = x.perfume left join pedidos pe on pe.codigo = x.ped order by x.n
  loop
    f := coalesce((select o.fecha from _v16_old o where o.perfume_id = r.pid and o.pedido_codigo = r.ped and o.cli = lower(r.cliente)),
                  r.fcob, r.fped, current_date);
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence)
    values (f, r.cliente, r.vend, r.pid, r.ped, r.unid, round(r.total / r.unid, 4), r.base,
            coalesce((select bcv from tasas where fecha <= f and bcv > 0 order by fecha desc limit 1),
                     (select bcv from tasas where bcv > 0 order by fecha desc limit 1), tb),
            binance_del_dia(f), r.vence)
    returning id into v_id;
    insert into _v16_id values (r.n, v_id);
  end loop;

  insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
  select i.id, coalesce(c.fecha, v.fecha), c.cuenta, c.monto, c.tasa
  from _v16_c c join _v16_id i on i.n = c.n join ventas v on v.id = i.id;

  -- Canje de José Montilva: pagó $20 vendiendo perfumes, no entró plata a la caja
  insert into movimientos (fecha, cuenta, monto, nota)
  select v.fecha, 'efectivo', -20, 'Canje: José Montilva pagó $20 vendiendo perfumes (no entró a la caja)'
  from _v16_id i join ventas v on v.id = i.id where i.n = 21;

  -- ---------- Clientes: se limpian los nombres repetidos que no tienen datos ----------
  delete from clientes cl where cl.telefono is null and cl.notas is null
    and not exists (select 1 from ventas v where lower(v.cliente) = lower(cl.nombre));
  insert into clientes (nombre) select distinct v.cliente from ventas v
    where not exists (select 1 from clientes c where lower(c.nombre) = lower(v.cliente));

  -- ---------- Pérdida: 1 Yara Candy defectuoso en el P-003 ----------
  update compras set unidades = unidades - 1
   where pedido_codigo = 'P-003' and unidades >= 3
     and perfume_id = (select pid from _v16_p where perfume = 'Lattafa Yara Candy Fem');
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'otro', 'Pérdida de inventario: 1 Yara Candy defectuoso (P-003, costo $12)', 12, 'P-003', null, null
  where not exists (select 1 from gastos where concepto like 'Pérdida de inventario: 1 Yara Candy%');
  -- Gastos que se mantienen: taxi $11 y arroz chino $20 (se crean solo si faltan)
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'traslado', 'Taxi para transportar los perfumes', 11, 'P-004', 'efectivo', 'Juan'
  where not exists (select 1 from gastos where concepto ilike '%taxi%');
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'otro', 'Arroz chino para comer', 20, null, 'efectivo', 'Juan'
  where not exists (select 1 from gastos where concepto ilike '%arroz chino%');

  -- ---------- Caja: efectivo $67, Binance $76, banco 2.600 Bs ----------
  select coalesce(max(saldo) filter (where cuenta = 'efectivo'), 0), coalesce(max(saldo) filter (where cuenta = 'binance'), 0),
         coalesce(max(saldo) filter (where cuenta = 'bs'), 0) into s_ef, s_bin, s_bs from caja_v;
  raise notice 'Caja según las ventas registradas: efectivo %, Binance %, Bs %.', round(s_ef, 2), round(s_bin, 2), round(s_bs, 2);

  -- Los Bs de más se registran como compra de divisa INFERIDA (sin merma; reemplázala con tus cifras reales)
  bs_conv := s_bs - t_bs;
  if bs_conv > 0.005 then
    div := round(bs_conv / tb, 2);
    pe := greatest(t_ef - s_ef, 0); pb := greatest(t_bin - s_bin, 0); tot := pe + pb;
    a_e := case when tot <= 0.005 then div else round(div * pe / tot, 2) end; a_b := div - a_e;
    bs_e := case when div > 0 then round(bs_conv * a_e / div, 2) else 0 end; bs_b := bs_conv - bs_e;
    if a_e > 0.005 then insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_e, a_e, 'efectivo', tb, 'Inferida (no tengo los datos reales de la compra): reemplázala con tus cifras'); end if;
    if a_b > 0.005 then insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_b, a_b, 'binance', tb, 'Inferida (no tengo los datos reales de la compra): reemplázala con tus cifras'); end if;
  end if;

  -- Lo que aún difiere del conteo real se anota aparte, como inciso (concilia = true)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-01', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de las ventas registradas'
                   else 'Faltante por conciliar: la caja real es menor a lo que muestran las ventas' end, true);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v16_reemplazo_ventas');
end $$;
