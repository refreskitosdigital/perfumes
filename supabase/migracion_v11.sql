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
