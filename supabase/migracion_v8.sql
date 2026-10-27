-- =====================================================================
-- MIGRACIÓN V8 · Gastos, rentabilidad y carga del LOTE 3 (ventas y cobros)
-- Ejecutar DESPUÉS de migracion_v7.sql. No borra ni cambia lo ya cargado.
-- Las partes de CARGA se aplican UNA sola vez (se anotan en cargas_hechas),
-- así que si la repites no duplica ventas ni cobros.
-- =====================================================================

-- ---------- 1. GASTOS (delivery, traslados, empaques, etc.) ----------
create table if not exists gastos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  categoria text not null default 'otro'
    check (categoria in ('delivery','traslado','empaque','publicidad','comision','otro')),
  concepto text not null,
  monto numeric not null check (monto > 0),                       -- siempre en $
  pedido_codigo text references pedidos(codigo) on update cascade on delete set null,  -- vacío = gasto general
  cuenta text check (cuenta in ('binance','efectivo')),           -- de qué caja salió; vacío = lo puso un socio
  pagado_por text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table gastos enable row level security;
drop policy if exists solo_socios on gastos;
create policy solo_socios on gastos for all using (es_socio()) with check (es_socio());

-- Control interno de cargas únicas
create table if not exists cargas_hechas (clave text primary key, hecho timestamptz not null default now());
alter table cargas_hechas enable row level security;
drop policy if exists solo_socios on cargas_hechas;
create policy solo_socios on cargas_hechas for all using (es_socio()) with check (es_socio());

-- La agenda puede llevar una nota (quién lo vendió, detalles)
alter table agenda_pedidos add column if not exists nota text;

-- Un gasto pagado desde la caja baja el saldo de esa cuenta
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
) x group by cuenta;

-- ---------- 2. RENTABILIDAD ----------
-- Por pedido: ganancia bruta (vendido − costo), gastos del pedido y ganancia neta
create or replace view rentabilidad_pedido_v with (security_invoker = true) as
select g.codigo, g.fecha, g.inversion, g.ventas_usd, g.cobrado_usd, g.pendiente_usd,
       g.costo_vendido, g.ganancia as ganancia_bruta,
       coalesce(x.gastos, 0) as gastos,
       g.ganancia - coalesce(x.gastos, 0) as ganancia_neta
from ganancia_pedido_v g
left join (select pedido_codigo, sum(monto) gastos from gastos where pedido_codigo is not null group by pedido_codigo) x
  on x.pedido_codigo = g.codigo;

-- Por socio: cada pedido reparte (ganancia − gastos del pedido) según la participación de cada socio
create or replace view rentabilidad_socios_v with (security_invoker = true) as
select ps.socio,
       sum(ps.aporte) as aportes,
       sum(r.ganancia_bruta * ps.participacion) as ganancia_bruta,
       sum(r.gastos * ps.participacion) as gastos,
       sum(r.ganancia_neta * ps.participacion) as ganancia_neta
from pedido_socios ps
join rentabilidad_pedido_v r on r.codigo = ps.pedido_codigo
group by ps.socio;

-- =====================================================================
-- 3. CARGA DEL LOTE 3  (una sola vez)
-- =====================================================================
-- Busca un perfume por nombre exacto o, si tu catálogo lo tiene escrito distinto, por una parte del nombre
create or replace function v8_buscar_perfume(p_nombre text, p_patron text) returns bigint
language sql stable as $f$
  select id from perfumes
  where lower(trim(nombre)) = lower(trim(p_nombre)) or nombre ~* p_patron
  order by (lower(trim(nombre)) = lower(trim(p_nombre))) desc, length(nombre), id
  limit 1
$f$;

do $$
declare
  tv numeric; tb numeric; faltan text;
  v_id bigint; pid bigint; r record; cod text;
begin
  if exists (select 1 from cargas_hechas where clave = 'v8_lote3') then
    raise notice 'La carga del lote 3 ya se había aplicado: no se repite.';
    return;
  end if;

  -- Tasa de venta (BCV Euro, o BCV si no hay euro) y Binance del día más reciente
  select coalesce(euro, bcv), binance into tv, tb from tasas order by fecha desc limit 1;
  if tv is null then raise exception 'Primero registra la tasa de hoy en la pestaña Tasas y vuelve a ejecutar esto.'; end if;

  -- ---- 3.1 Cambio de Moschino (no llegó) por Bharara Viking en el pedido P-003 ----
  if v8_buscar_perfume('Bharara Viking', 'viking') is null then insert into perfumes (nombre) values ('Bharara Viking'); end if;
  update compras set perfume_id = v8_buscar_perfume('Bharara Viking', 'viking')
  where pedido_codigo = 'P-003'
    and perfume_id = v8_buscar_perfume('Moschino Toy Boy', 'moschino');

  -- ---- 3.2 Perfumes que no estaban en el catálogo ----
  if v8_buscar_perfume('Lattafa Yara Moi', 'yara.*moi') is null then insert into perfumes (nombre) values ('Lattafa Yara Moi'); end if;
  if v8_buscar_perfume('Mont Blanc Legend Spirit', 'legend.*spirit') is null then insert into perfumes (nombre) values ('Mont Blanc Legend Spirit'); end if;

  -- ---- 3.3 Ventas del lote 3 ----
  -- (cliente, vendedor, perfume, unidades, precio_unit $, vence, nota, cobrado ahora en efectivo)
  drop table if exists pg_temp._v8_lote3;
  create temp table _v8_lote3 (cliente text, vendedor text, perfume text, unid int, precio numeric,
                        vence date, nota text, cobrado numeric, pedido text, patron text) on commit drop;
  insert into _v8_lote3 values
   ('Lory Teran',        'Juan',    'Ariana Grande Cloud',                     1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'cloud'),
   ('Lory Teran',        'Juan',    'Ariana Grande Mod Blush',                 1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'mod blush'),
   ('Elvys Castillo',    'Juan',    'Victorinox',                              1, 25, '2026-10-30', 'Swiss Army Classic. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'victorinox|swiss army'),
   ('Rosalba Montilva',  'Juan',    'Lancome La Vie Est Belle',       1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'la vie est belle'),
   ('Carola Carvajal',   'George',  'Armaf Odyssey Mandarin Sky Elixir',       1, 30, '2026-10-30', 'Con Yara Moi: total $60. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'mandari[n]e? sky'),
   ('Carola Carvajal',   'George',  'Lattafa Yara Moi',                        1, 30, '2026-10-30', 'Con Mandarin Sky: total $60. Pagará 50% el 30/10 y 50% el 15/11. REVISAR: Yara Moi no está en las compras del lote 3', 0, 'P-003', 'yara.*moi'),
   ('Rosalba Guitian',   'Rosanny', 'Carolina Herrera Good Girl Fem',          1, 30, '2026-10-30', 'Precio $30 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'good girl'),
   ('Jhoanny',           'Rosanny', 'Lattafa Yara Candy Fem',                  1, 35, '2026-10-30', 'Precio $35 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'yara candy'),
   ('Dra. Yexy',         'Juan',    'Victoria Secret Splash 250ml (variados)', 2, 7.5,'2026-10-30', 'Splash Coconut ×2 (total $15). Paga el 30/10', 0, 'P-003', 'splash'),
   ('Juan Teran',        'Juan',    'Victoria Secret Splash 250ml (variados)', 2, 7.5,'2026-10-30', 'Splash Juice Berry ×2 (total $15). Paga el 30/10', 0, 'P-003', 'splash'),
   ('Keylin Cabrera',    'Juan',    'Ariana Grande Thank U Next',              1, 25, null,         'Pagó en efectivo', 25, 'P-003', 'thank u next'),
   ('Juan Teran',        'Juan',    '9 PM Night Out',                          1, 35, '2026-10-30', 'Precio $35 BCV. Paga el 30/10', 0, 'P-003', '9 ?pm'),
   ('Almari',            'Rosanny', 'Lattafa Yara Fem',                        1, 35, '2026-10-30', 'Yara Clásico, precio $35 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', '^(lattafa )?yara( fem)?( cl.sic[oa])?$'),
   ('Jesus Teran',       'Juan',    'One Million Paco Rabanne',                1, 20, '2026-10-30', 'Pagará el 30/10 y el 15/11 (mitad y mitad)', 0, 'P-003', 'one million'),
   ('Jesus Teran',       'Juan',    'Bestia Negra',                            1, 20, '2026-10-30', 'Club de Nuit. Pagará el 30/10 y el 15/11 (mitad y mitad)', 0, 'P-003', 'bestia negra|club de nuit'),
   -- Reserva sin stock: venta anticipada (se descuenta cuando llegue la compra)
   ('Mauricio Garcez',   'Juan',    'Mont Blanc Legend Spirit',                1, 25, null,         'Reserva: pagó $10, debe $15. Hay que comprarlo (está en la Agenda)', 10, null, 'legend.*spirit');

  select string_agg(distinct perfume, ', ') into faltan from _v8_lote3 where v8_buscar_perfume(perfume, patron) is null;
  if faltan is not null then raise exception 'No encuentro estos perfumes en tu catálogo: %. Avísame cómo se llaman y lo ajusto.', faltan; end if;

  for r in select * from _v8_lote3 loop
    pid := v8_buscar_perfume(r.perfume, r.patron);
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base,
                        tasa_bcv, tasa_binance, vence, nota)
    values ('2026-10-24', r.cliente, r.vendedor, pid, r.pedido, r.unid, r.precio, 'divisa', tv, tv, r.vence, r.nota)
    returning id into v_id;
    if r.cobrado > 0 then
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-24', 'efectivo', r.cobrado);
    end if;
  end loop;

  -- ---- 3.4 Pagos recibidos sobre ventas que ya estaban registradas ----
  -- Luisa Teran: $25 por el Afnan 9am (efectivo)
  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'luisa teran%' and pf.nombre ilike '%9am%' order by v.id desc limit 1;
  if v_id is null then raise notice 'REVISAR: no encontré la venta del 9am de Luisa Teran; registra su pago de $25 a mano.';
  else insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-24', 'efectivo', 25); end if;

  -- Anny Guitian: mitad de los splash ($7,50) pagada en Bs a tasa BCV
  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'anny guitian%' and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise notice 'REVISAR: no encontré la venta de splash de Anny Guitian; registra su pago de $7,50 a mano.';
  else insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance)
       values (v_id, '2026-10-24', 'bs', round(7.5 * tv, 2), tv); end if;

  -- ---- 3.5 Agenda: perfumes por comprar (los costos son estimados con los del lote 3; edítalos en Agenda) ----
  select 'A-' || lpad((count(*) + 1)::text, 3, '0') into cod from agenda_pedidos;
  while exists (select 1 from agenda_pedidos where codigo = cod) or exists (select 1 from pedidos where codigo = cod) loop
    cod := 'A-' || lpad((substr(cod, 3)::int + 1)::text, 3, '0');
  end loop;
  insert into agenda_pedidos (codigo, fecha_prevista, proveedor, envio, registrado, nota)
  values (cod, null, null, 0, false,
          'Pendientes por comprar. Splash: 1 Pure Seduction + 1 Vainilla Lace. Los vendió Wilesmar. Incluye la reserva de Mauricio Garcez (Mont Blanc Legend Spirit).');
  insert into agenda_socios (codigo, socio, aporte) select cod, nombre, 0 from socios;
  insert into agenda_lineas (codigo, nombre, unidades, costo_unitario, precio_detal) values
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Carolina Herrera 212 VIP', '212 vip')), 'Carolina Herrera 212 VIP'), 2, 11, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Lattafa Yara Fem', '^(lattafa )?yara( fem)?( cl.sic[oa])?$')), 'Lattafa Yara Fem'), 1, 12, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Armaf Odyssey Mandarin Sky Elixir', 'mandari[n]e? sky')), 'Armaf Odyssey Mandarin Sky Elixir'), 1, 13, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Bestia Negra', 'bestia negra|club de nuit')), 'Bestia Negra'), 1, 12, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('9 PM Night Out', '9 ?pm')), '9 PM Night Out'), 1, 13, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Victoria Secret Splash 250ml (variados)', 'splash')), 'Victoria Secret Splash 250ml (variados)'), 2, 3,  null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Mont Blanc Legend Spirit', 'legend.*spirit')), 'Mont Blanc Legend Spirit'), 1, 13, null);

  insert into cargas_hechas (clave) values ('v8_lote3');
  raise notice 'Lote 3 cargado: % ventas. Agenda creada: %', (select count(*) from _v8_lote3), cod;
end $$;

drop function if exists v8_buscar_perfume(text, text);
