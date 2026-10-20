-- =====================================================================
-- MIGRACIÓN V3 · Clientes, Pagos y "Realizar pedido" con financiamiento
-- Se ejecuta UNA VEZ en el SQL Editor, DESPUÉS de schema.sql y de los seeds.
-- Es segura de repetir: no borra datos ni duplica lo que ya existe.
-- =====================================================================

-- ---------- CLIENTES ----------
create table if not exists clientes (
  id bigint generated always as identity primary key,
  nombre text not null,
  telefono text,
  notas text,
  creado date not null default current_date
);
create unique index if not exists clientes_nombre_uq on clientes (lower(trim(nombre)));

-- Cada venta nueva crea al cliente si todavía no existe
create or replace function cliente_auto() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  insert into clientes (nombre) values (trim(new.cliente)) on conflict do nothing;
  return new;
end $$;
drop trigger if exists ventas_cliente_auto on ventas;
create trigger ventas_cliente_auto before insert on ventas
  for each row execute function cliente_auto();

-- Clientes de las ventas que ya existen
insert into clientes (nombre)
select distinct on (lower(trim(cliente))) trim(cliente) from ventas
where trim(cliente) <> ''
on conflict do nothing;

-- ---------- PAGOS (historial transparente para todos los socios) ----------
-- tipo: 'proveedor' (compra de un pedido), 'deuda' (devolución de un préstamo), 'otro'
-- fuente: de dónde salió el dinero: 'caja', 'socio' (puso efectivo un socio), 'prestamo'
create table if not exists pagos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  tipo text not null check (tipo in ('proveedor','deuda','otro')),
  concepto text not null,
  pedido_codigo text references pedidos(codigo) on update cascade on delete set null,
  prestamo_id bigint references prestamos(id) on delete set null,
  monto numeric not null check (monto > 0),                 -- siempre en $
  cuenta text check (cuenta in ('binance','efectivo','bs')),
  estado text not null default 'pendiente' check (estado in ('pendiente','pagado')),
  fecha_pago date,
  fuente text check (fuente in ('caja','socio','prestamo')),
  pagado_por text,
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);

-- ---------- Funciones ----------
-- Registrar un pedido de la Agenda (ahora con fecha). Reemplaza a la versión anterior.
drop function if exists registrar_pedido(text);
create or replace function registrar_pedido(p_codigo text, p_fecha date default null) returns text
language plpgsql security invoker set search_path = public as $$
declare a agenda_pedidos%rowtype;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into a from agenda_pedidos where codigo = p_codigo for update;
  if not found then raise exception 'El pedido % no existe en la Agenda', p_codigo; end if;
  if a.registrado then raise exception 'El pedido % ya está registrado', p_codigo; end if;

  perform crear_pedido(
    a.codigo, coalesce(p_fecha, current_date), a.proveedor, a.envio,
    (select coalesce(jsonb_agg(jsonb_build_object('socio', socio, 'aporte', aporte)), '[]'::jsonb)
       from agenda_socios where codigo = p_codigo),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', nombre, 'unidades', unidades,
        'costo_unitario', costo_unitario, 'precio_detal', precio_detal) order by id), '[]'::jsonb)
       from agenda_lineas where codigo = p_codigo));

  update agenda_pedidos set registrado = true where codigo = p_codigo;
  return p_codigo;
end $$;

-- REALIZAR PEDIDO: pasa el pedido de la Agenda a Compras/Inventario y registra de dónde sale el dinero.
--   p_caja:   [{"cuenta":"binance","monto":45,"usd":45}, ...]  (monto en la moneda de la cuenta, usd = su valor en $)
--   p_socios: [{"socio":"Rosanny","monto":100}, ...]           (efectivo que pone un socio directamente)
--   p_prestamo: lo que presta p_prestamista para completar (queda como deuda)
--   p_pagar_despues: true = se registra el pedido pero el pago al proveedor queda PENDIENTE
create or replace function realizar_pedido(
  p_codigo text, p_fecha date, p_caja jsonb, p_socios jsonb,
  p_prestamo numeric, p_prestamista text, p_pagar_despues boolean default false
) returns text
language plpgsql security invoker set search_path = public as $$
declare
  a agenda_pedidos%rowtype;
  total numeric; x jsonb; f date := coalesce(p_fecha, current_date);
  cta text; m numeric; mu numeric; saldo numeric;
  suma numeric := 0; pr_id bigint;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into a from agenda_pedidos where codigo = p_codigo;
  if not found then raise exception 'El pedido % no existe en la Agenda', p_codigo; end if;
  total := coalesce((select sum(unidades * costo_unitario) from agenda_lineas where codigo = p_codigo), 0) + a.envio;
  if total <= 0 then raise exception 'El pedido % no tiene monto', p_codigo; end if;

  perform registrar_pedido(p_codigo, f);

  if p_pagar_despues then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado)
    values (f, 'proveedor', 'Pago al proveedor · pedido ' || p_codigo, p_codigo, total, 'pendiente');
    return p_codigo;
  end if;

  for x in select * from jsonb_array_elements(coalesce(p_caja, '[]'::jsonb)) loop
    cta := x ->> 'cuenta'; m := coalesce((x ->> 'monto')::numeric, 0); mu := coalesce((x ->> 'usd')::numeric, 0);
    continue when m <= 0;
    select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = cta;
    if m > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', cta, saldo; end if;
    insert into movimientos (fecha, cuenta, monto, nota) values (f, cta, -m, 'Pago del pedido ' || p_codigo || ' con la caja');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, cuenta, estado, fecha_pago, fuente)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · desde la caja (' || cta || ')', p_codigo, mu, cta, 'pagado', f, 'caja');
    suma := suma + mu;
  end loop;

  for x in select * from jsonb_array_elements(coalesce(p_socios, '[]'::jsonb)) loop
    m := coalesce((x ->> 'monto')::numeric, 0);
    continue when m <= 0;
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · efectivo de ' || (x ->> 'socio'), p_codigo, m, 'pagado', f, 'socio', x ->> 'socio');
    suma := suma + m;
  end loop;

  if coalesce(p_prestamo, 0) > 0 then
    insert into prestamos (fecha, descripcion, prestamista, monto)
    values (f, 'Préstamo para pagar el pedido ' || p_codigo, nullif(trim(p_prestamista), ''), p_prestamo)
    returning id into pr_id;
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · con préstamo', p_codigo, pr_id, p_prestamo, 'pagado', f, 'prestamo', nullif(trim(p_prestamista), ''));
    suma := suma + p_prestamo;
  end if;

  if abs(suma - total) > 0.011 then
    raise exception 'Lo pagado (%) no coincide con el total del pedido (%)', round(suma, 2), round(total, 2);
  end if;
  return p_codigo;
end $$;

-- Pagar un pago pendiente (de proveedor u otro) desde una cuenta de la caja o con dinero de un socio
create or replace function pagar_pendiente(
  p_id bigint, p_cuenta text, p_monto_cuenta numeric, p_pagado_por text, p_fecha date
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare pg pagos%rowtype; saldo numeric; f date := coalesce(p_fecha, current_date);
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into pg from pagos where id = p_id for update;
  if not found then raise exception 'El pago no existe'; end if;
  if pg.estado = 'pagado' then raise exception 'Ese pago ya está registrado como pagado'; end if;
  if p_cuenta in ('binance','efectivo','bs') then
    select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = p_cuenta;
    if coalesce(p_monto_cuenta, 0) > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', p_cuenta, saldo; end if;
    insert into movimientos (fecha, cuenta, monto, nota) values (f, p_cuenta, -p_monto_cuenta, 'Pago: ' || pg.concepto);
    update pagos set estado = 'pagado', fecha_pago = f, cuenta = p_cuenta, fuente = 'caja' where id = p_id;
  else
    update pagos set estado = 'pagado', fecha_pago = f, fuente = 'socio', pagado_por = p_pagado_por where id = p_id;
  end if;
  return p_id;
end $$;

-- Devolver (parte de) un préstamo: queda en el historial de pagos y baja la deuda
create or replace function pagar_deuda(
  p_prestamo bigint, p_monto_usd numeric, p_cuenta text, p_monto_cuenta numeric, p_fecha date
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare pr prestamos%rowtype; saldo numeric; f date := coalesce(p_fecha, current_date); nuevo bigint;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into pr from prestamos where id = p_prestamo for update;
  if not found then raise exception 'El préstamo no existe'; end if;
  if p_monto_usd <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_monto_usd > pr.monto - pr.devuelto + 0.011 then raise exception 'Es más de lo que se debe (%)', round(pr.monto - pr.devuelto, 2); end if;
  select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = p_cuenta;
  if coalesce(p_monto_cuenta, 0) > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', p_cuenta, saldo; end if;
  insert into movimientos (fecha, cuenta, monto, nota)
  values (f, p_cuenta, -p_monto_cuenta, 'Devolución de préstamo a ' || coalesce(pr.prestamista, 'prestamista') || ': ' || pr.descripcion);
  update prestamos set devuelto = devuelto + p_monto_usd where id = p_prestamo;
  insert into pagos (fecha, tipo, concepto, prestamo_id, monto, cuenta, estado, fecha_pago, fuente, pagado_por)
  values (f, 'deuda', 'Pago de deuda a ' || coalesce(pr.prestamista, 'prestamista') || ' · ' || pr.descripcion,
          p_prestamo, p_monto_usd, p_cuenta, 'pagado', f, 'caja', null)
  returning id into nuevo;
  return nuevo;
end $$;

-- ---------- Historial de pagos de los pedidos ya cargados (solo si Pagos está vacío) ----------
do $$
begin
  if exists (select 1 from pagos) then return; end if;

  if exists (select 1 from pedidos where codigo = 'P-001') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-07', 'proveedor', 'Pedido P-001 · efectivo de ' || socio, 'P-001', aporte, 'pagado', '2026-10-07', 'socio', socio
    from pedido_socios where pedido_codigo = 'P-001' order by socio;
  end if;

  if exists (select 1 from pedidos where codigo = 'P-002') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-16', 'proveedor', 'Pedido P-002 · con préstamo', 'P-002', pr.id, 254, 'pagado', '2026-10-16', 'prestamo', pr.prestamista
    from (select id, prestamista from prestamos where descripcion like '%P-002%' order by id limit 1) pr;
  end if;

  if exists (select 1 from pedidos where codigo = 'P-003') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, cuenta, estado, fecha_pago, fuente) values
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (binance)', 'P-003', 45, 'binance', 'pagado', '2026-10-19', 'caja'),
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (efectivo)', 'P-003', 235, 'efectivo', 'pagado', '2026-10-19', 'caja'),
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (bs)', 'P-003', 48.33, 'bs', 'pagado', '2026-10-19', 'caja');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por) values
      ('2026-10-19', 'proveedor', 'Pedido P-003 · efectivo de Rosanny', 'P-003', 100, 'pagado', '2026-10-19', 'socio', 'Rosanny');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-19', 'proveedor', 'Pedido P-003 · con préstamo (' ||
           case when descripcion like '%Rosanny%' then 'tercio de Rosanny' else 'diferencia' end || ')',
           'P-003', id, monto, 'pagado', '2026-10-19', 'prestamo', prestamista
    from prestamos where descripcion like '%P-003%' order by id;
  end if;
end $$;

-- ---------- Seguridad: solo los socios ven y escriben ----------
do $$
declare t text;
begin
  foreach t in array array['clientes','pagos'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
  end loop;
end $$;
