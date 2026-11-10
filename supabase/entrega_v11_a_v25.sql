-- =====================================================================
-- ENTREGA ÚNICA · migraciones v11 + v12 + cobros 30/10 + v13 + v14 + v16 + v17 + v18 + v19 + v20 + v21 + v22 + v23 + v24 + v25
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

-- >>>>>>>>>> migracion_v16.sql <<<<<<<<<<
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

-- >>>>>>>>>> migracion_v17.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v17 · Pagos del 2/11 y compra de $50 en Binance
-- Ejecutar DESPUÉS de migracion_v16.sql. Se aplica UNA sola vez aunque la repitas.
--  Cobros (fecha 2/11):
--   Wuile Kyomu · Starwalker           $13 efectivo (queda $2)
--   María Fernanda Kyomu · Amber Rouge + Splash   44.606,42 Bs a tasa 991,25 = $45 (le queda La Bomba $35)
--   Jesus Zapatero · Mandarin Sky Elixir          12.400 Bs a 992 = $12,50
--   Elvys Castillo · Victorinox                   24.850 Bs contados como $25 (pagó completo)
--   Wuile Kyomu · Bestia Negra                    13.902 Bs a 992 = $14,01
--   Carola Carvajal · Mandarin Elixir + Yara Tous 35.600 Bs contados como $40 ($30 y $10)
--  Compra de divisa: 50.058,42 Bs (44.100 + 5.958,42) por $50 en Binance.
--  Caja resultante: efectivo $80, Binance $126, banco 83.900 Bs.
-- =====================================================================
do $$
declare
  r record; v_id bigint; bcv_ref numeric; tb numeric; cta text; delta numeric;
  t_ef constant numeric := 80; t_bin constant numeric := 126; t_bs constant numeric := 83900;
begin
  if exists (select 1 from cargas_hechas where clave = 'v17_pagos_2nov') then
    raise notice 'La v17 ya estaba aplicada. No se repite.'; return;
  end if;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  for r in select * from (values
      ('wuile kyomu',          'starwalker',  'efectivo', 13::numeric,   null::numeric),
      ('maría fernanda kyomu', 'amber rouge', 'bs',       34693.22,      991.2538),
      ('maría fernanda kyomu', 'splash',      'bs',       9913.20,       991.2538),
      ('jesus zapatero',       'mandarin sky elixir', 'bs', 12400,       992),
      ('elvys castillo',       'victorinox',  'bs',       24850,         994),
      ('wuile kyomu',          'bestia negra','bs',       13902,         992),
      ('carola carvajal',      'mandarin sky elixir', 'bs', 26700,       890),
      ('carola carvajal',      'yara tous',   'bs',       8900,          890)
    ) as t(cliente, perfume, cuenta, monto, tasa)
  loop
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) = norm_txt(r.cliente) and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%'
       and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%" para "%". No se aplicó nada.', r.cliente, r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-02', r.cuenta, r.monto, r.tasa);
  end loop;

  -- Compra de $50 en Binance con 50.058,42 Bs
  insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
  values ('2026-11-02', 50058.42, 50, 'binance', coalesce(bcv_ref, tb), 'Compra de $50 en Binance: 44.100 Bs + 5.958,42 Bs');

  -- Si la caja no queda exactamente en el conteo real, la diferencia se anota aparte (inciso)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-02', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de las ventas registradas'
                   else 'Faltante por conciliar: la caja real es menor a lo que muestran las ventas' end, true);
      raise notice 'Ajuste de conciliación en %: %', cta, round(delta, 2);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v17_pagos_2nov');
end $$;

-- >>>>>>>>>> migracion_v18.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v18 · Gastos a cargo de ciertos socios, pagos/bonificaciones a socios y el almuerzo del 2/11
-- Ejecutar DESPUÉS de migracion_v17.sql. Se aplica UNA sola vez aunque la repitas.
--  1. gastos.socios: a quién se le descuenta el gasto (vacío = a todos los socios, como hasta ahora).
--  2. retiros_socios: bonificaciones, reparto de ganancia u otros pagos a un socio. Descuentan de la caja.
--  3. Gasto: almuerzo de Juan y George, 32.022 Bs a tasa BCV $ 891,10 = $35,94, mitad y mitad (no afecta a Rosanny).
--     Lo pagaron ellos de su bolsillo, así que no baja la caja.
-- =====================================================================
alter table gastos add column if not exists socios text[];

create table if not exists retiros_socios (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  socio text not null,
  tipo text not null default 'bonificacion' check (tipo in ('bonificacion','reparto','otro')),
  cuenta text not null check (cuenta in ('efectivo','binance','bs')),
  monto numeric not null check (monto > 0),          -- en $ (efectivo/Binance) o en Bs (cuenta bs)
  tasa numeric check (tasa > 0),                      -- solo Bs: tasa a la que se valora en dólares
  monto_usd numeric not null check (monto_usd > 0),   -- lo que equivale en dólares
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table retiros_socios enable row level security;
drop policy if exists solo_socios on retiros_socios;
create policy solo_socios on retiros_socios for all using (es_socio()) with check (es_socio());

-- La caja: lo que se le paga a un socio sale de la cuenta de la que se tomó
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
  union all select cuenta, -monto from retiros_socios
  union all select 'bs', -bs from conversiones
  union all select cuenta, divisa from conversiones
) x group by cuenta;

-- Almuerzo del 2/11
insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por, socios)
select '2026-11-02', 'otro', 'Almuerzo de Juan y George (32.022 Bs a tasa BCV $ 891,10)', round(32022 / 891.10, 2), null, null, 'Juan y George', array['Juan', 'George']
where not exists (select 1 from gastos where concepto like 'Almuerzo de Juan y George%');

insert into cargas_hechas (clave) values ('v18_socios_almuerzo') on conflict do nothing;

-- >>>>>>>>>> migracion_v19.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v19 · El almuerzo del 2/11 se pagó del banco (Bs)
-- Ejecutar DESPUÉS de migracion_v18.sql. Se aplica UNA sola vez.
-- 32.022 Bs a tasa BCV $ 891,10 salen de la caja en bolívares: 16.011 Bs a cargo de Juan y 16.011 Bs a cargo de George ($17,97 cada uno).
-- Rosanny no se afecta. Se quita el gasto del almuerzo de la v18 para no descontarlo dos veces.
-- =====================================================================
do $$
begin
  if exists (select 1 from cargas_hechas where clave = 'v19_almuerzo_banco') then
    raise notice 'La v19 ya estaba aplicada. No se repite.'; return;
  end if;

  delete from gastos where concepto like 'Almuerzo de Juan y George%';

  insert into retiros_socios (fecha, socio, tipo, cuenta, monto, tasa, monto_usd, nota)
  select '2026-11-02', s, 'otro', 'bs', 16011, 891.10, round(16011 / 891.10, 2),
         'Almuerzo de Juan y George: 32.022 Bs a tasa BCV $ 891,10 (mitad cada uno)'
  from unnest(array['Juan','George']) s;

  insert into cargas_hechas (clave) values ('v19_almuerzo_banco');
end $$;

-- >>>>>>>>>> migracion_v20.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v20 · Pagos del 3/11 y del 5/11 + venta nueva de 212 VIP Rose a Johenis
-- Ejecutar DESPUÉS de migracion_v19.sql. Se aplica UNA sola vez aunque la repitas.
--  Venta nueva: Carolina Herrera 212 VIP Rose Fem a Johenis Canguro, $25 (costo $13,50, comprada el 5/11 en el pedido P-005).
--  Cobros (se cuentan los $ dichos; la tasa guardada es Bs ÷ $, igual que en la v17):
--   3/11  Johenis Canguro   11.975 Bs  = $12,50 (mitad del 212 VIP Rose, tasa euro 991,25)
--   3/11  María Fernanda Kyomu  34.927,28 Bs = $35 (La Bomba, tasa euro 991,25)
--   3/11  Rosanny Cequea    13.350 Bs  = $15 (splash, BCV $ 889)
--   5/11  Carlos Gonzales (Wuile)  12.575,41 Bs = $12,50 (mitad, tasa euro 1.000)
--   5/11  Veronica          $20 en efectivo (212 VIP Rose Fem)
--   5/11  Lori Teran        25.150,82 Bs = $25 (Mod Blush, tasa 1.000)
--   5/11  Rosalba Guitian   13.423,31 Bs = $15 (Good Girl, BCV $ 894)
-- =====================================================================
do $$
declare
  r record; v_id bigint; v_perf bigint; tb numeric; tbcv numeric;
begin
  if exists (select 1 from cargas_hechas where clave = 'v20_pagos_3_5nov') then
    raise notice 'La v20 ya estaba aplicada. No se repite.'; return;
  end if;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  select bcv into tbcv from tasas where bcv > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  -- ---------- Pedido P-005: 1 unidad de 212 VIP Rose Fem a $13,50 (comprada el 5/11) ----------
  select id into v_perf from perfumes
   where norm_txt(nombre) = norm_txt('Carolina Herrera 212 VIP Rose Fem')
      or norm_txt(nombre) like '%212 vip rose%' order by id limit 1;
  if v_perf is null then raise exception 'No encontré el perfume 212 VIP Rose en el catálogo.'; end if;

  insert into pedidos (codigo, fecha, proveedor, envio) values ('P-005', '2026-11-05', null, 0) on conflict do nothing;
  insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
    ('P-005', 'Juan', 4.50, 1.0/3), ('P-005', 'George', 4.50, 1.0/3), ('P-005', 'Rosanny', 4.50, 1.0/3)
  on conflict do nothing;
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario) values ('P-005', v_perf, 1, 13.50);

  -- ---------- Venta a Johenis Canguro (3/11) ----------
  insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance)
  values ('2026-11-03', 'Johenis Canguro', 'Juan', v_perf, 'P-005', 1, 25, 'divisa',
          coalesce((select bcv from tasas where fecha <= '2026-11-03' and bcv > 0 order by fecha desc limit 1), tbcv, tb),
          coalesce((select binance from tasas where fecha <= '2026-11-03' and binance > 0 order by fecha desc limit 1), tb));

  -- ---------- Cobros ----------
  for r in select * from (values
      ('2026-11-03'::date, 'johenis canguro',         '212 vip rose',  'bs',       11975::numeric,  12.50::numeric),
      ('2026-11-03',       'maría fernanda kyomu',    'bomba',         'bs',       34927.28,        35),
      ('2026-11-03',       'rosanny cequea',          'splash',        'bs',       13350,           15),
      ('2026-11-05',       'carlos gonzales',         '',              'bs',       12575.41,        12.50),
      ('2026-11-05',       'veronica',                '212 vip rose',  'efectivo', 20,              20),
      ('2026-11-05',       'lori teran',              'mod blush',     'bs',       25150.82,        25),
      ('2026-11-05',       'rosalba guitian',         'good girl',     'bs',       13423.31,        15)
    ) as t(fecha, cliente, perfume, cuenta, monto, usd)
  loop
    v_id := null;
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) like norm_txt(r.cliente) || '%' and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%'
       and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%" (%). No se aplicó nada.', r.cliente, r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
    values (v_id, r.fecha, r.cuenta, r.monto, case when r.cuenta = 'bs' then round(r.monto / r.usd, 4) end);
  end loop;

  insert into cargas_hechas (clave) values ('v20_pagos_3_5nov');
end $$;

-- >>>>>>>>>> migracion_v21.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v21 · Compras de divisa y de perfumes del 5/11, cobros de Kyuran y Jean Mary, cuadre de caja
-- Ejecutar DESPUÉS de migracion_v20.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Pago a Refreskitos (Juan) del 2/11: 29.760 Bs a tasa 992 = $30 (solo si no lo habías anotado ya).
--  2. Compras de divisa con bolívares (5/11): $30 a Binance (30.000 Bs) y $20 + $30 + $15 en efectivo (20.000 + 30.000 + 15.000 Bs), a 1.000 Bs por $.
--  3. Compra de perfumes para el P-005: 212 VIP Rose + Odyssey Home nuevo, $13,50 cada uno = $27 (27.351 Bs del banco).
--     El aporte del P-005 sube de $13,50 a $27 ($9 cada socio).
--  4. Kyuran paga $40 por Binance (Lacoste $30 + splash $10). Pagó $50: los $10 de vuelto se le dieron en Bs (10.000 Bs a 1.000).
--  5. Jean Mary de la Hoz abona $60 por Binance a sus ventas más antiguas con saldo.
--  6. Cuadre al conteo real: efectivo $165, Binance $216, banco 41.297 Bs. Cualquier diferencia se anota aparte
--     como "Sobrante/Faltante por conciliar" (inciso), sin tocar lo demás.
-- =====================================================================
do $$
declare
  r record; v_id bigint; v_perf bigint; bcv_ref numeric; tb numeric; cta text; delta numeric; resto numeric; aplica numeric;
  t_ef constant numeric := 165; t_bin constant numeric := 216; t_bs constant numeric := 41297;
begin
  if exists (select 1 from cargas_hechas where clave = 'v21_compras_5nov') then
    raise notice 'La v21 ya estaba aplicada. No se repite.'; return;
  end if;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  -- 1. Pago a Juan (si no estaba)
  insert into retiros_socios (fecha, socio, tipo, cuenta, monto, tasa, monto_usd, nota)
  select '2026-11-02', 'Juan', 'reparto', 'bs', 29760, 992, 30, 'Pago a Refreskitos: 29.760 Bs a tasa 992 = $30'
  where not exists (select 1 from retiros_socios where fecha = '2026-11-02' and socio = 'Juan' and monto = 29760);

  -- 2. Compras de divisa
  insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota) values
    ('2026-11-05', 30000, 30, 'binance',  coalesce(bcv_ref, tb), 'Compra de $30 en Binance a 1.000'),
    ('2026-11-05', 20000, 20, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $20 en efectivo a Rosangela a 1.000'),
    ('2026-11-05', 30000, 30, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $30 en efectivo a 1.000'),
    ('2026-11-05', 15000, 15, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $15 en efectivo a 1.000');

  -- 3. Perfumes del P-005 (212 VIP Rose ya está) + Odyssey Home nuevo
  insert into perfumes (nombre) values ('Odyssey Home') on conflict do nothing;
  select id into v_perf from perfumes where lower(trim(nombre)) = 'odyssey home';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario) values ('P-005', v_perf, 1, 13.50);
  update pedido_socios set aporte = 9 where pedido_codigo = 'P-005';
  insert into movimientos (fecha, cuenta, monto, nota)
  values ('2026-11-05', 'bs', -27351, 'Compra de perfumes P-005: 212 VIP Rose + Odyssey Home ($27 a $13,50 c/u)');

  -- 4. Kyuran: $40 por Binance y $10 de vuelto en Bs
  for r in select * from (values ('lacoste white', 30::numeric), ('splash', 10::numeric)) as t(perfume, usd) loop
    v_id := null;
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) = 'kyuran' and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%' and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de Kyuran (%). No se aplicó nada.', r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-05', 'binance', r.usd);
  end loop;
  insert into movimientos (fecha, cuenta, monto, nota) values
    ('2026-11-05', 'binance', 10, 'Kyuran pagó $50 por Binance y debía $40: $10 de vuelto'),
    ('2026-11-05', 'bs', -10000, 'Vuelto a Kyuran: $10 en Bs a 1.000');

  -- 5. Jean Mary de la Hoz: $60 a sus ventas más antiguas con saldo
  resto := 60;
  for r in select v.id, v.pendiente_usd from ventas_v v
            where norm_txt(v.cliente) like norm_txt('jean mary') || '%' and v.pendiente_usd > 0.01 order by v.fecha, v.id loop
    exit when resto <= 0.005;
    aplica := least(resto, r.pendiente_usd);
    insert into cobros (venta_id, fecha, cuenta, monto) values (r.id, '2026-11-05', 'binance', round(aplica, 2));
    resto := resto - aplica;
  end loop;
  if resto > 0.01 then raise exception 'A Jean Mary de la Hoz le sobran $% sin venta con saldo. No se aplicó nada.', round(resto, 2); end if;

  -- 6. Cuadre al conteo real (la diferencia queda como inciso aparte)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-05', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de lo registrado'
                   else 'Faltante por conciliar: la caja real es menor a lo registrado' end, true);
      raise notice 'Ajuste de conciliación en %: %', cta, round(delta, 2);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v21_compras_5nov');
end $$;

-- >>>>>>>>>> migracion_v22.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v22 · Dos correcciones al cuadre del 5/11
-- Ejecutar DESPUÉS de migracion_v21.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Los $50 que faltaban en Binance están guardados en Zelle: se aclara en la nota del ajuste.
--  2. Del conteo de 41.297 Bs se descuentan 10.000 del vuelto de Kyuran (conteo real: 31.297 Bs).
-- =====================================================================
do $$
begin
  if exists (select 1 from cargas_hechas where clave = 'v22_zelle_vuelto') then
    raise notice 'La v22 ya estaba aplicada. No se repite.'; return;
  end if;

  update movimientos
     set nota = 'Estos $50 no están en Binance: están guardados en Zelle'
   where concilia and cuenta = 'binance' and monto = -50 and fecha = '2026-11-05';

  insert into movimientos (fecha, cuenta, monto, nota, concilia)
  values ('2026-11-05', 'bs', -10000, 'Corrección del conteo: de los 41.297 Bs se descuentan 10.000 del vuelto de Kyuran (conteo real 31.297 Bs)', true);

  insert into cargas_hechas (clave) values ('v22_zelle_vuelto');
end $$;

-- >>>>>>>>>> migracion_v23.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v23 · Abono de $20 en efectivo del cliente Carpintero (5/11)
-- Ejecutar DESPUÉS de migracion_v22.sql. Se aplica UNA sola vez aunque la repitas.
-- Carpintero compró el Bharara Viking Kashmir ($45): abona $20 y le quedan $25.
-- =====================================================================
do $$
declare v_id bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'v23_carpintero_5nov') then
    raise notice 'La v23 ya estaba aplicada. No se repite.'; return;
  end if;
  select v.id into v_id from ventas_v v
   where norm_txt(v.cliente) = 'carpintero' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo del cliente Carpintero. No se aplicó nada.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-05', 'efectivo', 20);
  insert into cargas_hechas (clave) values ('v23_carpintero_5nov');
end $$;

-- >>>>>>>>>> migracion_v24.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v24 · Pagos del 6/11 y del 9/11
-- Ejecutar DESPUÉS de migracion_v23.sql. Se aplica UNA sola vez aunque la repitas.
-- Cada pago se aplica a las ventas más antiguas del cliente que tengan saldo.
-- Se cuentan los $ dichos; la tasa guardada es Bs ÷ $ (igual que en v17 y v20).
--   6/11  Hijo del Carpintero  13.410 Bs = $15 (BCV $ 894)
--   (Luisa Teran, 17.500 Bs = $20, queda aparte: solo debía $15)
--   6/11  Jessica Green Hair   26.910 Bs = $30 (BCV $ 897)
--   6/11  Yeimy Green Hair     $30 en efectivo
--   9/11  Jesus Zapatero       12.514 Bs = $12,50 (BCV $ 897,53)
-- =====================================================================
do $$
declare
  r record; s record; resto numeric; aplica numeric;
begin
  if exists (select 1 from cargas_hechas where clave = 'v24_pagos_6_9nov') then
    raise notice 'La v24 ya estaba aplicada. No se repite.'; return;
  end if;

  for r in select * from (values
      ('2026-11-06'::date, 'hijo del carpintero', 'bs',       13410::numeric,  15::numeric),
      ('2026-11-06',       'jessica green hair',  'bs',       26910,           30),
      ('2026-11-06',       'yeimy green hair',    'efectivo', 30,              30),
      ('2026-11-09',       'jesus zapatero',      'bs',       12514,           12.50)
    ) as t(fecha, cliente, cuenta, monto, usd)
  loop
    resto := r.usd;
    for s in select v.id, v.pendiente_usd from ventas_v v
              where norm_txt(v.cliente) = norm_txt(r.cliente) and v.pendiente_usd > 0.01 order by v.fecha, v.id loop
      exit when resto <= 0.005;
      aplica := least(resto, s.pendiente_usd);
      insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
      values (s.id, r.fecha, r.cuenta,
              case when r.cuenta = 'bs' then round(r.monto * aplica / r.usd, 2) else round(aplica, 2) end,
              case when r.cuenta = 'bs' then round(r.monto / r.usd, 4) end);
      resto := resto - aplica;
    end loop;
    if resto > 0.01 then raise exception 'A "%" le sobran $% sin venta con saldo. No se aplicó nada.', r.cliente, round(resto, 2); end if;
  end loop;

  insert into cargas_hechas (clave) values ('v24_pagos_6_9nov');
end $$;

-- >>>>>>>>>> migracion_v25.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v25 · Cuarto perfume de Jean Mary de la Hoz: Paco Rabanne One Million Lucky
-- Ejecutar DESPUÉS de migracion_v24.sql. Se aplica UNA sola vez aunque la repitas.
-- En la carga del P-003 ese perfume quedó a nombre de "Jema de La Hoz" (error de escritura): se pasa a Jean Mary de la Hoz.
-- Si no existía esa venta, se crea ($30 · P-003 · vence 15/11 · vendedor George).
-- =====================================================================
do $$
declare v_perf bigint; n int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v25_jean_mary_cuarto') then
    raise notice 'La v25 ya estaba aplicada. No se repite.'; return;
  end if;

  update ventas set cliente = 'Jean Mary de la Hoz'
   where norm_txt(cliente) in ('jemadelahoz', 'jeanmarydelahoz', 'jeanmarydelahoz')
     and perfume_id in (select id from perfumes where norm_txt(nombre) like '%onemillionlucky%')
     and cliente <> 'Jean Mary de la Hoz';
  get diagnostics n = row_count;

  if n = 0 and not exists (select 1 from ventas v join perfumes p on p.id = v.perfume_id
                           where norm_txt(v.cliente) = 'jeanmarydelahoz' and norm_txt(p.nombre) like '%onemillionlucky%') then
    select id into v_perf from perfumes where norm_txt(nombre) like '%onemillionlucky%' order by id limit 1;
    if v_perf is null then raise exception 'No encontré Paco Rabanne One Million Lucky en el catálogo.'; end if;
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence)
    values ('2026-10-30', 'Jean Mary de la Hoz', 'George', v_perf, 'P-003', 1, 30, 'divisa',
            (select bcv from tasas where bcv > 0 order by fecha desc limit 1),
            (select binance from tasas where binance > 0 order by fecha desc limit 1), '2026-11-15');
  end if;

  -- Si había un cliente "Jema de La Hoz" suelto en la lista y ya no tiene ventas, se quita
  delete from clientes c where norm_txt(c.nombre) = 'jemadelahoz'
    and not exists (select 1 from ventas v where norm_txt(v.cliente) = 'jemadelahoz');

  insert into cargas_hechas (clave) values ('v25_jean_mary_cuarto');
end $$;
