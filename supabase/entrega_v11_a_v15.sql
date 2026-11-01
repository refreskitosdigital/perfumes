-- =====================================================================
-- ENTREGA ÚNICA · migraciones v11 + v12 + cobros 30/10 + v13 + v14 + v15
-- Requisito: ya tener corridas las migraciones hasta la v10.
-- ANTES de ejecutar: en la app (Tasa del día) guarda hoy las 3 tasas: BCV Euro, Binance y BCV $.
-- Cada bloque se aplica una sola vez; si repites el archivo no duplica nada.
-- =====================================================================

-- >>>>>>>>>> migracion_v11.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v11 · Pedido 3 corregido, orden manual de perfumes y conversión Bs → divisa (merma)
-- Ejecutar DESPUÉS de migracion_v10.sql. Es segura de repetir (la corrección del pedido 3 se aplica una sola vez).
--
--  1. Pedido 3: se reemplaza su lista de compras por la lista real recibida (50 perfumes, $505) y los
--     17 decants porta perfumes ($21, no se venden) se anotan como gasto del pedido. Se renombran los
--     perfumes que llegaron con otro nombre y se ocultan los que no llegaron (si no tienen compras ni ventas).
--  2. perfumes.orden: orden manual de la tienda (se arrastra en Inventario). Marcas parecidas quedan juntas.
--  3. conversiones: registra cuando compras divisa con Bs. Calcula la merma (lo que se pierde en el cambio)
--     y mueve la caja: sale Bs, entra divisa.
-- =====================================================================

-- ---------- 1. Orden manual de los perfumes ----------
alter table perfumes add column if not exists orden int;

create or replace function perfumes_ordenar(p_ids bigint[]) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  update perfumes set orden = x.n
  from unnest(p_ids) with ordinality as x(id, n)
  where perfumes.id = x.id;
end $$;

-- La tienda y las vendedoras ven los perfumes en el orden manual
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text, marca text, genero text, notas text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion,
         nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), '')
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.orden nulls last, pf.nombre;
$$;

create or replace function vend_catalogo(p_token text)
returns table (id bigint, nombre text, descripcion text, foto_url text, foto2_url text,
               precio_consigna numeric, precio_sugerido numeric, disponible boolean,
               marca text, genero text, notas text, tips_venta text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return query
    select pf.id, pf.nombre, pf.descripcion, pf.foto_url, pf.foto2_url, pf.precio_consigna, pf.precio_detal, s.stock > 0,
           nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), ''), nullif(trim(pf.tips_venta), '')
    from perfumes pf join stock_efectivo() s on s.perfume_id = pf.id
    where pf.visible_vendedoras and pf.precio_consigna is not null
    order by pf.orden nulls last, pf.nombre;
end $$;

-- ---------- 2. Conversión de Bs a divisa y merma ----------
create table if not exists conversiones (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  bs numeric not null check (bs > 0),                          -- bolívares que se entregaron
  divisa numeric not null check (divisa > 0),                  -- dólares que se recibieron
  cuenta text not null default 'binance' check (cuenta in ('binance','efectivo')),   -- dónde entró la divisa
  tasa_bcv numeric not null check (tasa_bcv > 0),              -- BCV $ con la que se cobraron esos Bs (interna)
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table conversiones enable row level security;
drop policy if exists solo_socios on conversiones;
create policy solo_socios on conversiones for all using (es_socio()) with check (es_socio());

-- Merma = lo que esos Bs valían a la tasa BCV $ del cobro, menos la divisa que de verdad se recibió
create or replace view conversiones_v with (security_invoker = true) as
select c.*,
       round(c.bs / c.divisa, 4) as tasa_real,
       round(c.bs / c.tasa_bcv, 2) as esperado_usd,
       round(c.bs / c.tasa_bcv - c.divisa, 2) as merma_usd,
       round((c.bs / c.tasa_bcv - c.divisa) / (c.bs / c.tasa_bcv), 4) as merma_pct
from conversiones c;

-- La caja: la conversión saca los Bs y mete la divisa
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
  union all select 'bs', -bs from conversiones
  union all select cuenta, divisa from conversiones
) x group by cuenta;

-- ---------- 3. Pedido 3: corrección ----------
create or replace function v11_renombrar(p_viejo text, p_nuevo text) returns void
language plpgsql set search_path = public as $$
begin
  if exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_viejo)))
     and not exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_nuevo))) then
    update perfumes set nombre = p_nuevo where lower(trim(nombre)) = lower(trim(p_viejo));
    update agenda_lineas set nombre = p_nuevo where lower(trim(nombre)) = lower(trim(p_viejo));
  end if;
end $$;

create or replace function v11_perfume(p_nombre text, p_marca text, p_genero text) returns void
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_nombre))) then
    insert into perfumes (nombre, marca, genero) values (p_nombre, p_marca, p_genero);
  end if;
end $$;

do $$
declare
  r record; f record; faltan text := ''; ventas_movidas text := ''; saldo int; v record; pid bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'p3_correccion_v11') then
    raise notice 'La corrección del pedido 3 ya estaba aplicada. No se repite.';
    return;
  end if;
  if not exists (select 1 from pedidos where codigo = 'P-003') then
    raise notice 'No existe el pedido P-003: se omite la corrección.';
    return;
  end if;

  -- Nombres que llegaron distintos
  perform v11_renombrar('Lattafa Yara Fem', 'Lattafa Yara Clásico');
  perform v11_renombrar('Lattafa Mayar Lujo Premium', 'Lattafa Mayar Natural Intense');
  perform v11_renombrar('Victorinox', 'Victorinox Swiss Army Classic');
  perform v11_renombrar('Perry Ellis 360', 'Perry Ellis 360 for Men');
  perform v11_renombrar('Perry Ellis Coral', 'Perry Ellis 360 Coral');
  -- La Vie Est Belle: se renombra sin importar cómo esté escrita hoy en tu catálogo
  if not exists (select 1 from perfumes where lower(trim(nombre)) = lower('Lancôme La Vie Est Belle'))
     and exists (select 1 from perfumes where nombre ~* 'la vie est belle') then
    update agenda_lineas set nombre = 'Lancôme La Vie Est Belle' where nombre ~* 'la vie est belle';
    update perfumes set nombre = 'Lancôme La Vie Est Belle'
     where id = (select id from perfumes where nombre ~* 'la vie est belle' order by id limit 1);
  end if;
  perform v11_renombrar('Bharara Viking', 'Bharara Viking Kashmir Lujo');
  update perfumes set marca = 'Lancôme' where lower(nombre) = lower('Lancôme La Vie Est Belle');

  -- Perfumes nuevos que llegaron
  perform v11_perfume('Paco Rabanne One Million Lucky', 'Paco Rabanne', 'hombre');
  perform v11_perfume('Valentino Donna Fem', 'Valentino', 'mujer');
  perform v11_perfume('Carolina Herrera 212 VIP Rose Fem', 'Carolina Herrera', 'mujer');
  perform v11_perfume('Lattafa Yara Tous Fem', 'Lattafa', 'mujer');
  perform v11_perfume('Afnan 9am Dive Unisex', 'Afnan', 'unisex');

  -- Lista real del pedido 3 (50 perfumes · $505). El splash: $26 por los 10 = $2,60 c/u.
  create temp table _p3 (nombre text, unid int, costo numeric) on commit drop;
  insert into _p3 values
    ('Ariana Grande Cloud', 2, 11.5), ('Ariana Grande Thank U Next', 2, 11.5), ('Bestia Negra', 2, 12),
    ('Bharara Rose Fem Lujo Premium', 1, 16), ('Carolina Herrera 212 VIP Black', 1, 11), ('Carolina Herrera 212 VIP Fem', 1, 11),
    ('Carolina Herrera Good Girl Fem', 1, 11), ('Lancôme La Vie Est Belle', 1, 10), ('Lattafa Art of Universe', 1, 19),
    ('Lattafa Mayar Natural Intense', 1, 16), ('Lattafa Yara Clásico', 3, 12), ('Lattafa Yara Candy Fem', 3, 12),
    ('Paco Rabanne Invictus Intense', 1, 10), ('Invictus Parfum Paco Rabanne', 1, 11), ('Paco Rabanne One Million Lucky', 1, 11),
    ('Fantasy', 2, 10), ('Armaf Odyssey Mandarin Sky Elixir', 2, 12.5), ('Ariana Grande Mod Blush', 1, 11),
    ('Ariana Grande Mod Vainilla', 1, 11), ('Victorinox Swiss Army Classic', 2, 10.5), ('9 PM Night Out', 2, 13),
    ('Perry Ellis 360 Coral', 1, 10), ('Perry Ellis 360 for Men', 1, 10), ('Armaf Odyssey Tyrant Men', 1, 13),
    ('Valentino Donna Fem', 1, 12), ('Victoria Secret Splash 250ml (variados)', 10, 2.6), ('Carolina Herrera 212 VIP Rose Fem', 1, 11),
    ('Bharara Viking Kashmir Lujo', 1, 18), ('Lattafa Yara Tous Fem', 1, 12), ('Afnan 9am Dive Unisex', 1, 11);

  for r in select t.nombre from _p3 t where not exists (select 1 from perfumes pf where lower(trim(pf.nombre)) = lower(trim(t.nombre))) loop
    faltan := faltan || E'\n  • ' || r.nombre;
  end loop;
  if faltan <> '' then
    raise exception 'No se encontraron estos perfumes y no se aplicó nada:%', faltan;
  end if;

  -- Reemplazar las compras del pedido 3
  delete from compras where pedido_codigo = 'P-003';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
  select 'P-003', pf.id, t.unid, t.costo from _p3 t join perfumes pf on lower(trim(pf.nombre)) = lower(trim(t.nombre));

  -- Las ventas atadas al pedido 3 de perfumes que ya no llegaron (o que llegaron menos) pasan a "anticipadas"
  for f in
    select v2.perfume_id, sum(v2.unidades) vendidas,
           coalesce((select sum(c.unidades) from compras c where c.pedido_codigo = 'P-003' and c.perfume_id = v2.perfume_id), 0) comprados
    from ventas v2 where v2.pedido_codigo = 'P-003' group by v2.perfume_id
  loop
    saldo := f.vendidas - f.comprados;
    if saldo > 0 then
      for v in select id, unidades, cliente from ventas where pedido_codigo = 'P-003' and perfume_id = f.perfume_id order by id desc loop
        exit when saldo <= 0;
        update ventas set pedido_codigo = null where id = v.id;
        saldo := saldo - v.unidades;
        ventas_movidas := ventas_movidas || E'\n  • venta #' || v.id || ' de ' || v.cliente || ' (' || (select nombre from perfumes where id = f.perfume_id) || ')';
      end loop;
    end if;
  end loop;
  if ventas_movidas <> '' then
    raise notice 'Estas ventas ya no tienen stock en el pedido 3 y quedaron como anticipadas (se ven en Por comprar):%', ventas_movidas;
  end if;

  -- Los perfumes que no llegaron y no tienen compras ni ventas dejan de verse en la tienda y para las vendedoras
  update perfumes pf set visible_tienda = false, visible_vendedoras = false
  where lower(trim(pf.nombre)) in ('lattafa asad men', 'santal 33', 'valentino born in roma intense', 'moschino toy boy', 'one million paco rabanne')
    and not exists (select 1 from compras c where c.perfume_id = pf.id)
    and not exists (select 1 from ventas v3 where v3.perfume_id = pf.id);

  -- Los 17 decants porta perfumes: no se venden, son un gasto del pedido
  if not exists (select 1 from gastos where concepto like '17 decants porta perfumes%') then
    insert into gastos (fecha, categoria, concepto, monto, pedido_codigo)
    values ('2026-10-19', 'empaque', '17 decants porta perfumes para muestras (no se venden)', 21, 'P-003');
  end if;

  insert into cargas_hechas (clave) values ('p3_correccion_v11');
end $$;

drop function if exists v11_renombrar(text, text);
drop function if exists v11_perfume(text, text, text);

-- ---------- 4. Orden inicial: marcas parecidas juntas (solo a los que aún no tienen orden) ----------
update perfumes pf set orden = x.n + coalesce((select max(orden) from perfumes), 0)
from (select id, row_number() over (order by (nullif(trim(marca), '') is null), lower(trim(marca)), lower(nombre)) n
      from perfumes where orden is null) x
where pf.id = x.id;

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'vend_catalogo(text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
  execute 'revoke all on function perfumes_ordenar(bigint[]) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function perfumes_ordenar(bigint[]) from anon';
    execute 'grant execute on function perfumes_ordenar(bigint[]) to authenticated';
  end if;
end $$;

-- >>>>>>>>>> migracion_v12.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v12 · Cierre del lote 3 con lo que quedó en existencia (30/10)
-- Ejecutar DESPUÉS de migracion_v11.sql. Se aplica UNA sola vez aunque la repitas.
-- ANTES: en "Tasa del día" guarda hoy las 3 tasas: BCV Euro, Binance y BCV $ (dólar).
--  - Cambia 3 ventas agendadas por el perfume que de verdad se entregó (Carola, Almari, Rosangela).
--  - Ajusta las fechas de pago de Jhoany Guitian (Yara Candy).
--  - Registra las ventas nuevas que faltaban y el gasto de $20 (comida) pagado en efectivo.
-- NO toca la caja: el conteo real se ajusta desde la pestaña Caja ("Conteo real").
-- =====================================================================

create or replace function v12_bcv(p_fecha date) returns numeric
language sql stable as $f$
  select coalesce(
    (select bcv from tasas where fecha <= p_fecha and bcv > 0 order by fecha desc limit 1),
    (select bcv from tasas where bcv > 0 order by fecha desc limit 1))
$f$;

create or replace function v12_perf(p_nombre text) returns bigint
language plpgsql stable as $f$
declare pid bigint;
begin
  select id into pid from perfumes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if pid is null then raise exception 'No encuentro el perfume "%" en tu catálogo. Avísame cómo se llama.', p_nombre; end if;
  return pid;
end $f$;

do $$
declare
  eu numeric; tb numeric; tbcv numeric; v_id bigint; r record; n int := 0;
begin
  if exists (select 1 from cargas_hechas where clave = 'v12_lote3_final') then
    raise notice 'El cierre del lote 3 ya estaba aplicado. No se repite.'; return;
  end if;
  select euro, binance into eu, tb from tasas order by fecha desc limit 1;
  tbcv := v12_bcv(current_date);
  if coalesce(eu, 0) <= 0 or coalesce(tb, 0) <= 0 or coalesce(tbcv, 0) <= 0 then
    raise exception 'Primero guarda en "Tasa del día" las 3 tasas de hoy (BCV Euro, Binance y BCV $) y vuelve a ejecutar esto.';
  end if;

  -- ---------- 1. Ventas agendadas que cambiaron de perfume ----------
  -- Carola: la Yara Moi (que no llegó) se cambió por la Yara Tous que estaba disponible
  update ventas set perfume_id = v12_perf('Lattafa Yara Tous Fem'), pedido_codigo = 'P-003',
         nota = 'Con Mandarin Sky: total $60. Cambió la Yara Moi agendada por la Yara Tous. Pagará 50% el 30/10 y 50% el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Carola Carvajal' and pf.nombre = 'Lattafa Yara Moi' order by v.id limit 1);

  -- Almari: no se llevó la Yara; la cambió por la Bharara Rose Lujo Premium ($45 BCV $)
  update ventas set perfume_id = v12_perf('Bharara Rose Fem Lujo Premium'), pedido_codigo = 'P-003', precio_unit = 45,
         base = 'bcv', tasa_bcv = v12_bcv(fecha), vendedor = 'Rosanny', vence = '2026-11-15',
         nota = 'Cambió la Yara por la Bharara Rose. $45 BCV$. Paga la mitad el 31/10 y la otra mitad el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Almari' and pf.nombre = 'Lattafa Yara Clásico' order by v.id limit 1);

  -- Rosangela Cequea: se llevó el Valentino Donna Fem en vez del que tenía agendado (sus cobros se conservan)
  update ventas set perfume_id = v12_perf('Valentino Donna Fem'), pedido_codigo = 'P-003', vendedor = 'Rosanny',
         nota = trim(coalesce(nota || ' · ', '') || 'Se llevó el Donna Fem en vez del agendado')
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Rosangela Cequea' and pf.nombre = 'Valentino Donna Intense' order by v.id limit 1);

  -- Jhoany Guitian (Yara Candy, vendida por Rosanny): $35 BCV $, paga 31/10 y 15/11
  update ventas set cliente = 'Jhoany Guitian', base = 'bcv', tasa_bcv = v12_bcv(fecha), vence = '2026-11-15',
         nota = 'Yara Candy. $35 BCV$. Paga el 31/10 y el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Jhoanny' and pf.nombre = 'Lattafa Yara Candy Fem' order by v.id limit 1);

  -- ---------- 2. Ventas nuevas (fecha 30/10) ----------
  -- (cliente, vendedor, perfume, precio, base, tasa_bcv, vence, nota)
  drop table if exists pg_temp._v12;
  create temp table _v12 (cliente text, vendedor text, perfume text, precio numeric, base text, tbcv numeric,
                          vence date, nota text) on commit drop;
  insert into _v12 values
   ('Jefren', 'Jose Montilva', '9 PM Night Out', 30, 'bcv', 888, null, '$30 BCV$ a 888 Bs por dólar. Pagó completo en Bs'),
   ('Hijo del Carpintero', 'Jose Montilva', 'Afnan 9am Dive Unisex', 35, 'bcv', tbcv, '2026-11-15', '$35 BCV$. Paga el 31/10 y el 15/11'),
   ('Juan Perez', 'Juan', 'Armaf Odyssey Mandarin Sky Elixir', 35, 'divisa', eu, '2026-11-15', 'Paga la mitad el 31/10 y la otra mitad el 15/11'),
   ('Frank Transportista', 'Wuilesmar', 'Bestia Negra', 30, 'bcv', eu, '2026-11-15', '$30 BCV Euro. Primera mitad el 30/10 (aún por cobrar) y la otra el 15/11'),
   ('Carpintero', 'Jose Montilva', 'Bharara Viking Kashmir Lujo', 45, 'bcv', tbcv, '2026-11-15', '$45 BCV$. Paga la mitad el 31/10 y la otra mitad el 15/11'),
   ('Cliente de Gardimar', 'Wuilesmar', 'Carolina Herrera 212 VIP Rose Fem', 25, 'bcv', eu, null, '$25 BCV Euro. Aún por cobrar'),
   ('Andreina (esposa de Ismael)', 'Wuilesmar', 'Lattafa Yara Clásico', 25, 'divisa', eu, '2026-11-15', 'Paga la primera parte el 31/10 y la segunda el 15/11'),
   ('Jessica', 'George', 'Lattafa Yara Candy Fem', 30, 'bcv', tbcv, '2026-11-17', 'Yara Candy. $30 BCV$. Paga el 2/11 y el 17/11');

  for r in select * from _v12 loop
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values ('2026-10-30', r.cliente, r.vendedor, v12_perf(r.perfume), 'P-003', 1, r.precio, r.base, r.tbcv, tb, r.vence, r.nota)
    returning id into v_id;
    n := n + 1;
    if r.cliente = 'Jefren' then   -- pagó completo en bolívares: 30 × 888 = 26.640 Bs
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-30', 'bs', 30 * 888);
    end if;
  end loop;

  -- ---------- 3. Gasto de comida ($20 en efectivo) ----------
  insert into gastos (fecha, categoria, concepto, monto, cuenta, pagado_por)
  values ('2026-10-30', 'otro', 'Arroz chino para comer', 20, 'efectivo', 'Juan');

  insert into cargas_hechas (clave) values ('v12_lote3_final');
  raise notice 'Cierre del lote 3 aplicado: 4 ventas ajustadas, % ventas nuevas y 1 gasto.', n;
end $$;

drop function if exists v12_bcv(date);
drop function if exists v12_perf(text);

-- >>>>>>>>>> cobros_30oct.sql <<<<<<<<<<
-- Cobros del 30/10 (se aplica una sola vez aunque lo repitas)
--  · Anny Guitian: $7,50 de los splash que faltaban, pagados en Bs a BCV $ 888  -> 6.660 Bs
--  · Wuile Kyomu (Wuilesmar): $7 de su splash, pagados en Bs a BCV Euro 993    -> 6.951 Bs
do $$
declare v_id bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'cobros_30oct_splash') then
    raise notice 'Estos cobros ya estaban registrados. No se repite.'; return;
  end if;

  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'anny guitian%' and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise exception 'No encontré la venta de splash de Anny Guitian.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance) values (v_id, '2026-10-30', 'bs', round(7.5 * 888, 2), 888);

  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where (lower(v.cliente) like 'wuile%' ) and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise exception 'No encontré la venta de splash de Wuilesmar (Wuile Kyomu).'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance) values (v_id, '2026-10-30', 'bs', round(7 * 993, 2), 993);

  insert into cargas_hechas (clave) values ('cobros_30oct_splash');
end $$;

-- >>>>>>>>>> migracion_v13.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v13 · Lote 4 (P-004), sus ventas y dos cobros (1/11)
-- Ejecutar DESPUÉS de migracion_v12.sql. Se aplica UNA sola vez aunque la repitas.
-- Antes: en "Tasa del día" debe estar guardada la tasa de hoy (BCV Euro y Binance).
--  1. Cobros: Jesus Teran abona $20 (efectivo) y Doris Teran paga $35 (efectivo).
--  2. Pedido P-004: 26 perfumes, $352, aportado por los 3 socios en partes iguales.
--  3. Ventas del lote 4 y sus pagos.
--  4. Agenda A-001: se quitan los perfumes que ya llegaron en este lote.
-- NO mueve la caja: el lote se financió con aportes de los socios.
-- =====================================================================

create or replace function v13_perf(p_nombre text, p_marca text default null, p_genero text default null) returns bigint
language plpgsql as $f$
declare pid bigint;
begin
  select id into pid from perfumes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if pid is null then
    insert into perfumes (nombre, marca, genero, orden)
    values (p_nombre, p_marca, p_genero, coalesce((select max(orden) from perfumes), 0) + 1) returning id into pid;
  end if;
  return pid;
end $f$;

do $$
declare
  tv numeric; tb numeric; v_id bigint; n int := 0; r record; hay int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v13_lote4') then
    raise notice 'El lote 4 ya estaba cargado. No se repite.'; return;
  end if;
  select euro, binance into tv, tb from tasas order by fecha desc limit 1;
  if coalesce(tv, 0) <= 0 or coalesce(tb, 0) <= 0 then
    raise exception 'Primero guarda en "Tasa del día" la tasa de hoy (BCV Euro y Binance) y vuelve a ejecutar esto.';
  end if;

  -- ---------- 1. Cobros ----------
  select v.id into v_id from ventas_v v where lower(v.cliente) like 'jesus teran%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Jesus Teran.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', 'efectivo', 20);

  select v.id into v_id from ventas_v v where lower(v.cliente) like 'doris teran%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Doris Teran.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', 'efectivo', 35);

  -- ---------- 2. Pedido P-004 ----------
  insert into pedidos (codigo, fecha, proveedor, envio) values ('P-004', '2026-11-01', null, 0) on conflict do nothing;
  insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
    ('P-004', 'Juan', 117.33, 1.0/3), ('P-004', 'George', 117.33, 1.0/3), ('P-004', 'Rosanny', 117.34, 1.0/3)
  on conflict do nothing;

  drop table if exists pg_temp._p4;
  create temp table _p4 (pid bigint, unid int, costo numeric) on commit drop;
  insert into _p4 values
   (v13_perf('Bestia Negra'), 1, 12),                                                            -- Armaf Club de Nuit
   (v13_perf('Mont Blanc Legend Spirit'), 1, 10),
   (v13_perf('Lattafa Yara Moi'), 1, 12),
   (v13_perf('Victoria Secret Splash 250ml (variados)'), 1, 3),                                  -- Vainilla Lace
   (v13_perf('Bharara Rose Fem Lujo Premium'), 1, 16),
   (v13_perf('Lattafa Khamrah Karaz Unisex Lujo Premium'), 1, 16),
   (v13_perf('Carolina Herrera Good Girl Fem'), 1, 11),
   (v13_perf('9 PM Night Out'), 2, 13),
   (v13_perf('Armaf Odyssey Mandarin Sky', 'Armaf', 'hombre'), 1, 13),
   (v13_perf('Armaf Odyssey Mandarin Sky Elixir'), 1, 13),
   (v13_perf('Armaf Yum Yum Lujo Premium', 'Armaf', 'mujer'), 1, 19),
   (v13_perf('Armaf Infinity Gold Fem Lujo Premium', 'Armaf', 'mujer'), 1, 19),
   (v13_perf('Ariana Grande Mod Blush'), 1, 11),
   (v13_perf('Jean Paul Gaultier Scandal Intense Fem', 'Jean Paul Gaultier', 'mujer'), 1, 11),
   (v13_perf('Lattafa Emeer Unisex Lujo Premium', 'Lattafa', 'unisex'), 1, 19),
   (v13_perf('Bharara Kinh Soleil Lujo Premium', 'Bharara', null), 1, 17),
   (v13_perf('Xerjoff Erba Pure Lujo Premium', 'Xerjoff', 'unisex'), 1, 17),
   (v13_perf('Valentino Uomo Born in Roma', 'Valentino', 'hombre'), 2, 12),
   (v13_perf('Lattafa Noble Blush Lujo Premium', 'Lattafa', 'mujer'), 1, 14),
   (v13_perf('Armaf Odyssey Mandarine Sky Vintage Edition', 'Armaf', 'hombre'), 1, 13),
   (v13_perf('Armaf Odyssey Pink Pop Fem', 'Armaf', 'mujer'), 1, 13),
   (v13_perf('Armaf Odyssey Candee', 'Armaf', 'mujer'), 1, 13),
   (v13_perf('Al Haramain Amber Oud Gold Edition', 'Al Haramain', 'unisex'), 1, 15),
   (v13_perf('Lattafa Ajwad Lujo Premium', 'Lattafa', 'unisex'), 1, 15);
  delete from compras where pedido_codigo = 'P-004';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
  select 'P-004', pid, unid, costo from _p4;

  -- ---------- 3. Ventas del lote 4 (fecha 1/11) ----------
  drop table if exists pg_temp._v13;
  create temp table _v13 (cliente text, vendedor text, perfume text, precio numeric, base text, vence date, nota text,
                          cobro numeric, cuenta text, pedido text) on commit drop;
  insert into _v13 values
   ('Felix Aqua Vic', 'Juan', 'Bharara Kinh Soleil Lujo Premium', 40, 'divisa', '2026-11-15', 'Pagó la mitad ($20) y debe $20 para el 15/11', 20, 'efectivo', 'P-004'),
   ('Ariana Marquez', 'Juan', 'Carolina Herrera Good Girl Fem', 35, 'divisa', '2026-11-30', 'Paga la mitad el 15/11 y la otra mitad el 30/11', 0, null, 'P-004'),
   ('Adriana Aqua Vic', 'Juan', 'Armaf Odyssey Pink Pop Fem', 35, 'divisa', null, 'Pago completo por Binance', 35, 'binance', 'P-004'),
   ('Rosanna Aqua Vic', 'George', 'Ariana Grande Mod Blush', 35, 'bcv', '2026-11-15', '$35 BCV Euro. Paga la mitad el 2/11 y la otra mitad el 15/11', 0, null, 'P-004'),
   ('Jema de La Hoz', 'George', 'Armaf Odyssey Mandarin Sky', 30, 'divisa', '2026-11-15', 'Con One Million Lucky: total $60. Paga el 15/11', 0, null, 'P-004'),
   ('Jema de La Hoz', 'George', 'Paco Rabanne One Million Lucky', 30, 'divisa', '2026-11-15', 'Con Mandarin Sky: total $60. Paga el 15/11', 0, null, 'P-003');
  for r in select * from _v13 loop
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values ('2026-11-01', r.cliente, r.vendedor, v13_perf(r.perfume), r.pedido, 1, r.precio, r.base, tv, tb, r.vence, r.nota)
    returning id into v_id;
    n := n + 1;
    if r.cobro > 0 then
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', r.cuenta, r.cobro);
    end if;
  end loop;

  -- La reserva de Mauricio Garcez (Mont Blanc Legend Spirit) ya tiene su perfume: pasa al pedido P-004
  update ventas set pedido_codigo = 'P-004'
   where pedido_codigo is null and cliente = 'Mauricio Garcez' and perfume_id = v13_perf('Mont Blanc Legend Spirit');

  -- ---------- 4. Agenda A-001: quitar lo que ya llegó ----------
  delete from agenda_lineas
   where codigo = 'A-001' and unidades <= 1
     and nombre in ('Armaf Odyssey Mandarin Sky Elixir', 'Bestia Negra', '9 PM Night Out', 'Mont Blanc Legend Spirit', 'Victoria Secret Splash 250ml (variados)');
  update agenda_lineas set unidades = unidades - 1
   where codigo = 'A-001' and unidades > 1
     and nombre in ('Armaf Odyssey Mandarin Sky Elixir', 'Bestia Negra', '9 PM Night Out', 'Mont Blanc Legend Spirit', 'Victoria Secret Splash 250ml (variados)');

  insert into cargas_hechas (clave) values ('v13_lote4');
  raise notice 'Lote 4 cargado: % perfumes, % ventas nuevas, 2 cobros.', (select sum(unid) from _p4), n;
end $$;

drop function if exists v13_perf(text, text, text);

-- >>>>>>>>>> migracion_v14.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v14 · Todo en dólares, tasa BCV en cada cobro en Bs, merma por pedido y datos del 1/11
-- Ejecutar DESPUÉS de migracion_v13.sql. Las partes de CARGA se aplican una sola vez.
--
--  1. cobros.tasa_bcv: la tasa BCV a la que pagó el cliente en Bs. Los cobros viejos se completan solos.
--  2. Las ventas valen su monto en dólares ($35 son $35). Un cobro en Bs vale Bs ÷ tasa BCV pagada.
--  3. merma_cobros_v / merma_pedido_v: lo que se pierde por la brecha en cada cobro en Bs y por pedido
--     (BCV pagada contra Binance del día del cobro).
--  4. Datos: pago del lote 4 desde la caja ($345 efectivo), taxi $11, cobro de Eduin Torres,
--     segunda venta del Thank U Next y corrección del splash (eran 9, no 10, en el pedido 3).
-- =====================================================================

-- ---------- 1. Tasa BCV en cada cobro ----------
alter table cobros add column if not exists tasa_bcv numeric;
update cobros co set tasa_bcv = coalesce(co.tasa_binance, v.tasa_bcv)
from ventas v where v.id = co.venta_id and co.cuenta = 'bs' and co.tasa_bcv is null;

-- ---------- 2. Ventas en dólares nominales ----------
create or replace view ventas_v with (security_invoker = true) as
select x.*,
       x.valor_usd - x.cobrado_usd as pendiente_usd,
       x.costo_unit * x.unidades as costo_total,
       case when x.costo_unit is null then null else x.valor_usd - x.costo_unit * x.unidades end as ganancia
from (
  select v.*, pf.sku, pf.nombre,
         v.unidades * v.precio_unit as total_pactado,
         v.unidades * v.precio_unit as valor_usd,
         coalesce((select sum(case when co.cuenta = 'bs' then co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) else co.monto end)
                   from cobros co where co.venta_id = v.id), 0) as cobrado_usd,
         (select cp.costo_real from costos_pedido_v cp
           where cp.pedido_codigo = v.pedido_codigo and cp.perfume_id = v.perfume_id) as costo_unit
  from ventas v join perfumes pf on pf.id = v.perfume_id
) x;

-- ---------- 3. Merma por cobro en Bs y por pedido ----------
create or replace function binance_del_dia(p_fecha date) returns numeric
language sql stable as $f$
  select coalesce(
    (select binance from tasas where fecha <= p_fecha order by fecha desc limit 1),
    (select binance from tasas order by fecha limit 1))
$f$;

create or replace view merma_cobros_v with (security_invoker = true) as
select co.id as cobro_id, co.fecha, v.pedido_codigo, v.cliente, co.monto as bs,
       coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) as tasa_bcv,
       binance_del_dia(co.fecha::date) as binance_dia,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv), 2) as nominal_usd,
       round(co.monto / binance_del_dia(co.fecha::date), 2) as real_usd,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) - co.monto / binance_del_dia(co.fecha::date), 2) as merma_usd
from cobros co join ventas v on v.id = co.venta_id
where co.cuenta = 'bs';

create or replace view merma_pedido_v with (security_invoker = true) as
select coalesce(pedido_codigo, 'Sin pedido') as pedido_codigo,
       count(*)::int as cobros_bs, round(sum(bs), 2) as bs,
       round(sum(nominal_usd), 2) as nominal_usd, round(sum(real_usd), 2) as real_usd,
       round(sum(merma_usd), 2) as merma_usd
from merma_cobros_v group by 1;

-- ---------- 4. Datos del 30/10 al 1/11 (una sola vez) ----------
do $$
declare tv numeric; tb numeric; v_id bigint; pid bigint; ok_spl int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v14_datos_1nov') then
    raise notice 'Los datos de v14 ya estaban cargados. No se repiten.'; return;
  end if;
  select coalesce(euro, bcv), binance into tv, tb from tasas order by fecha desc limit 1;
  if coalesce(tv, 0) <= 0 or coalesce(tb, 0) <= 0 then
    raise exception 'Primero guarda en "Finanzas > Tasas" la tasa de hoy (BCV $, BCV Euro y Binance) y vuelve a ejecutar esto.';
  end if;

  -- Lote 4: pagado con la caja ($345 en efectivo)
  insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', -345, 'Pago del lote 4 (P-004) con la caja');

  -- Taxi para transportar los perfumes (sale de la caja, en efectivo)
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  values ('2026-10-30', 'traslado', 'Taxi para transportar los perfumes', 11, 'P-004', 'efectivo', 'Juan');

  -- Eduin Torres pagó sus $15 en Bs a BCV 994  ->  14.910 Bs
  select v.id into v_id from ventas_v v where lower(v.cliente) like 'eduin torre%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Eduin Torres.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-01', 'bs', 15 * 994, 994);

  -- Thank U Next: la segunda unidad también se la vendió a Keylin Cabrera por $25 en efectivo
  select id into pid from perfumes where lower(trim(nombre)) = 'ariana grande thank u next';
  if pid is null then raise exception 'No encuentro el perfume Ariana Grande Thank U Next.'; end if;
  insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
  values ('2026-10-30', 'Keylin Cabrera', 'Juan', pid, 'P-003', 1, 25, 'divisa', tv, tb, 'Segunda unidad del Thank U Next. Pagó en efectivo')
  returning id into v_id;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-30', 'efectivo', 25);

  -- Splash: en el pedido 3 llegaron 9 (no 10) por los mismos $26 en total
  update compras set unidades = 9, costo_unitario = round(26.0 / 9, 4)
   where pedido_codigo = 'P-003'
     and perfume_id = (select id from perfumes where nombre ilike 'Victoria Secret Splash%' order by id limit 1)
     and unidades = 10;
  get diagnostics ok_spl = row_count;
  if ok_spl = 0 then raise notice 'REVISAR: no encontré 10 splash en el pedido 3; corrige el splash a mano en Inventario.'; end if;

  insert into cargas_hechas (clave) values ('v14_datos_1nov');
end $$;

-- ---------- Permisos ----------
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function binance_del_dia(date) to authenticated;
  end if;
end $$;

-- >>>>>>>>>> migracion_v15.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v15 · Cobros del 1/11 y cuadre de la caja con tu conteo real
-- Ejecutar DESPUÉS de migracion_v14.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Cobros: Juan Perez $20 (efectivo), Hijo del Carpintero $20 en Bs a 993, Almari $22,50 en Bs a 889,
--     Andreina (esposa de Ismael) $17 en Bs a 991.
--  2. Cuadre: deja la caja en tu conteo real (efectivo $67, Binance $55, Bs 0). Los Bs que sobran en el sistema
--     se registran como COMPRA DE DIVISA (Bs entregados = todo el saldo en Bs; divisa recibida = lo que faltaba
--     para llegar a tus $67 y $55). Esos montos son inferidos: si tienes los reales, bórralos en
--     Finanzas > Caja > Convertir bolívares en divisa y regístralos con tus cifras.
-- =====================================================================
do $$
declare
  v_id bigint; r record; bcv_ref numeric;
  s_ef numeric; s_bin numeric; s_bs numeric;
  d_ef numeric; d_bin numeric; pe numeric; pb numeric; tot numeric; bs_e numeric; bs_b numeric;
  t_ef constant numeric := 67; t_bin constant numeric := 55;
begin
  if exists (select 1 from cargas_hechas where clave = 'v15_cobros_cuadre') then
    raise notice 'La v15 ya estaba aplicada. No se repite.'; return;
  end if;

  -- ---------- 1. Cobros ----------
  for r in select * from (values
      ('juan perez%',          'efectivo', 20::numeric,    null::numeric),
      ('hijo del carpintero%', 'bs',       20 * 993,       993),
      ('almari%',              'bs',       22.5 * 889,     889),
      ('andreina%',            'bs',       17 * 991,       991)
    ) as t(cliente, cuenta, monto, tasa)
  loop
    select v.id into v_id from ventas_v v where lower(v.cliente) like r.cliente and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%".', replace(r.cliente, '%', ''); end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-01', r.cuenta, r.monto, r.tasa);
  end loop;

  -- ---------- 2. Cuadre con el conteo real ----------
  select coalesce(max(saldo) filter (where cuenta = 'efectivo'), 0), coalesce(max(saldo) filter (where cuenta = 'binance'), 0),
         coalesce(max(saldo) filter (where cuenta = 'bs'), 0)
    into s_ef, s_bin, s_bs from caja_v;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  d_ef := t_ef - s_ef; d_bin := t_bin - s_bin;
  pe := greatest(d_ef, 0); pb := greatest(d_bin, 0); tot := pe + pb;

  if s_bs > 0.005 and tot > 0.005 and coalesce(bcv_ref, 0) > 0 then
    bs_e := round(s_bs * pe / tot, 2); bs_b := round(s_bs - bs_e, 2);
    if pe > 0.005 then
      insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_e, round(pe, 2), 'efectivo', bcv_ref, 'Inferida al cuadrar la caja: reemplaza con tus cifras reales');
    end if;
    if pb > 0.005 then
      insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_b, round(pb, 2), 'binance', bcv_ref, 'Inferida al cuadrar la caja: reemplaza con tus cifras reales');
    end if;
  elsif abs(s_bs) > 0.005 then
    insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'bs', -s_bs, 'Ajuste al conteo real de la caja');
  end if;

  -- Lo que sobre o falte en divisa tras la conversión se ajusta como movimiento
  if d_ef < -0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', round(d_ef, 2), 'Ajuste al conteo real de la caja'); end if;
  if d_bin < -0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'binance', round(d_bin, 2), 'Ajuste al conteo real de la caja'); end if;
  if not (s_bs > 0.005 and tot > 0.005 and coalesce(bcv_ref, 0) > 0) then
    if d_ef > 0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', round(d_ef, 2), 'Ajuste al conteo real de la caja'); end if;
    if d_bin > 0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'binance', round(d_bin, 2), 'Ajuste al conteo real de la caja'); end if;
  end if;

  insert into cargas_hechas (clave) values ('v15_cobros_cuadre');
  raise notice 'Antes del cuadre el sistema tenía: efectivo %, Binance %, Bs %.', round(s_ef, 2), round(s_bin, 2), round(s_bs, 2);
end $$;
