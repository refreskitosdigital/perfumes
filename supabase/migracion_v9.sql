-- =====================================================================
-- MIGRACIÓN V9 · Catálogo (perfumes con o sin inventario) y Vendedoras
-- Ejecutar DESPUÉS de migracion_v8.sql. No borra ni cambia datos existentes.
-- Es segura de repetir.
--
-- CATÁLOGO: cada perfume tiene 3 precios que no se mezclan:
--   precio_detal     -> lo que paga el público en la tienda online
--   precio_mayor     -> lo que paga el público al comprar el mayor (12 perfumes)
--   precio_consigna  -> lo que te debe una vendedora por cada perfume que vende
-- La tienda NUNCA recibe la consignación ni el costo; las vendedoras NUNCA ven el
-- precio al mayor ni el costo.
--
-- VENDEDORAS: entran a un link aparte con usuario + PIN (6 a 10 números), eligen
-- del catálogo, anotan a cuánto vendieron (nunca menos que la consignación) y tú
-- apruebas cada pedido. Al aprobar, se crea la venta a precio de consignación.
-- =====================================================================

-- ---------- 1. Catálogo: campos nuevos en perfumes ----------
alter table perfumes add column if not exists descripcion text;
alter table perfumes add column if not exists precio_consigna numeric check (precio_consigna >= 0);
alter table perfumes add column if not exists existencia_manual int check (existencia_manual >= 0);
alter table perfumes add column if not exists visible_vendedoras boolean not null default true;

-- Existencia real de cada perfume (la misma regla para la tienda y para las vendedoras):
--  * Si tiene compras registradas: compras − ventas − pedidos web nuevos.
--  * Si NO tiene compras (solo está en el catálogo): la existencia que anotes a mano − pedidos web nuevos.
create or replace function stock_efectivo()
returns table (perfume_id bigint, stock int, en_inventario boolean)
language sql stable security definer set search_path = public as $$
  select pf.id,
         greatest(case when c.u is not null then c.u - coalesce(v.u, 0) else coalesce(pf.existencia_manual, 0) end
                  - coalesce(w.u, 0), 0)::int,
         c.u is not null
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id;
$$;

-- La tienda: ahora con descripción y con la existencia del catálogo
drop function if exists tienda_catalogo();
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.nombre;
$$;

-- ---------- 2. Vendedoras ----------
create table if not exists vendedoras (
  id bigint generated always as identity primary key,
  nombre text not null,
  usuario text not null unique,
  salt text not null default replace(gen_random_uuid()::text, '-', ''),
  pin_hash text,
  activa boolean not null default true,
  intentos int not null default 0,
  bloqueado_hasta timestamptz,
  creada timestamptz not null default now()
);

create table if not exists vendedora_sesiones (
  token_hash text primary key,
  vendedora_id bigint not null references vendedoras(id) on delete cascade,
  expira timestamptz not null
);

create table if not exists pedidos_vendedora (
  id bigint generated always as identity primary key,
  vendedora_id bigint not null references vendedoras(id),
  creado timestamptz not null default now(),
  cliente text not null,
  telefono text,
  notas text,
  plan text not null default 'contado' check (plan in ('contado','mitades','otro')),
  fecha1 date,
  fecha2 date,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado','entregado')),
  nota_admin text,
  aprobado_por text,
  aprobado_en timestamptz
);

create table if not exists pedidos_vendedora_items (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_vendedora(id) on delete cascade,
  perfume_id bigint not null references perfumes(id),
  unidades int not null check (unidades > 0),
  precio_consigna numeric not null check (precio_consigna >= 0),   -- se congela al anotar el pedido
  precio_venta numeric not null check (precio_venta >= 0),         -- a cuánto vendió ella
  venta_id bigint references ventas(id) on delete set null,        -- la venta que se crea al aprobar
  check (precio_venta >= precio_consigna)
);

-- Lo que el cliente le fue pagando a la vendedora
create table if not exists cobros_vendedora (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_vendedora(id) on delete cascade,
  fecha date not null default current_date,
  monto numeric not null check (monto > 0),
  quien text not null,
  nota text,
  creado timestamptz not null default now()
);

-- Seguridad: solo los socios ven estas tablas; las vendedoras entran únicamente por las funciones de abajo
do $$
declare t text;
begin
  foreach t in array array['vendedoras','vendedora_sesiones','pedidos_vendedora','pedidos_vendedora_items','cobros_vendedora'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    if t <> 'vendedora_sesiones' then
      execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
    end if;
  end loop;
end $$;

-- Resumen por pedido de vendedora (lo usa el control y la app de vendedoras)
create or replace view vendedora_pedidos_v with (security_invoker = true) as
select p.id, p.vendedora_id, d.nombre as vendedora, p.creado, p.cliente, p.telefono, p.notas, p.plan, p.fecha1, p.fecha2,
       p.estado, p.nota_admin,
       coalesce(t.total_venta, 0) as total_venta,
       coalesce(t.total_consigna, 0) as total_consigna,
       coalesce(t.total_venta, 0) - coalesce(t.total_consigna, 0) as ganancia_vendedora,
       coalesce(c.cobrado, 0) as cobrado_cliente,
       coalesce(pg.pagado, 0) as pagado_perfumeria,
       case when p.estado in ('aprobado','entregado') and coalesce(t.total_venta, 0) > 0
            then greatest(least(coalesce(c.cobrado, 0), coalesce(t.total_consigna, 0)) - coalesce(pg.pagado, 0), 0)
            else 0 end as debe_perfumeria,
       -- la perfumería cobra primero su consignación; lo que pase de ahí es de la vendedora
       greatest(least(coalesce(c.cobrado, 0) - coalesce(t.total_consigna, 0), coalesce(t.total_venta, 0) - coalesce(t.total_consigna, 0)), 0) as ganancia_ganada
from pedidos_vendedora p
join vendedoras d on d.id = p.vendedora_id
left join (select pedido_id, sum(unidades * precio_venta) total_venta, sum(unidades * precio_consigna) total_consigna
           from pedidos_vendedora_items group by pedido_id) t on t.pedido_id = p.id
left join (select pedido_id, sum(monto) cobrado from cobros_vendedora group by pedido_id) c on c.pedido_id = p.id
left join (select i.pedido_id, sum(v.cobrado_usd) pagado
           from pedidos_vendedora_items i join ventas_v v on v.id = i.venta_id group by i.pedido_id) pg on pg.pedido_id = p.id;

-- ---------- 3. Funciones internas ----------
create or replace function vend_hash(p_texto text) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p_texto, ''), 'UTF8')), 'hex') $$;

-- Quién es la vendedora de esta sesión (o error si venció)
create or replace function vend_id(p_token text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  select s.vendedora_id into v
  from vendedora_sesiones s join vendedoras d on d.id = s.vendedora_id
  where s.token_hash = vend_hash(p_token) and s.expira > now() and d.activa;
  if v is null then raise exception 'Tu sesión venció. Entra de nuevo.'; end if;
  return v;
end $$;

-- ---------- 4. Funciones de la app de vendedoras (rol anon) ----------
-- Entrar con usuario + PIN. Tras 5 fallos seguidos se bloquea 15 minutos.
create or replace function vend_entrar(p_usuario text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d vendedoras%rowtype; tok text;
begin
  select * into d from vendedoras where usuario = lower(trim(coalesce(p_usuario, '')));
  if not found or not d.activa then
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'mensaje', 'Usuario o PIN incorrecto');
  end if;
  if d.bloqueado_hasta is not null and d.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'mensaje', 'Demasiados intentos. Prueba de nuevo en unos minutos.');
  end if;
  if d.pin_hash is null or d.pin_hash <> vend_hash(d.salt || ':' || coalesce(p_pin, '')) then
    update vendedoras set intentos = case when intentos + 1 >= 5 then 0 else intentos + 1 end,
                          bloqueado_hasta = case when intentos + 1 >= 5 then now() + interval '15 minutes' else bloqueado_hasta end
    where id = d.id;
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'mensaje', 'Usuario o PIN incorrecto');
  end if;
  update vendedoras set intentos = 0, bloqueado_hasta = null where id = d.id;
  delete from vendedora_sesiones where expira < now();
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into vendedora_sesiones (token_hash, vendedora_id, expira) values (vend_hash(tok), d.id, now() + interval '12 hours');
  return jsonb_build_object('ok', true, 'token', tok, 'nombre', d.nombre);
end $$;

-- El catálogo que ve la vendedora: SOLO consignación y precio sugerido (nunca costo ni precio al mayor)
create or replace function vend_catalogo(p_token text)
returns table (id bigint, nombre text, descripcion text, foto_url text, foto2_url text,
               precio_consigna numeric, precio_sugerido numeric, disponible boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return query
    select pf.id, pf.nombre, pf.descripcion, pf.foto_url, pf.foto2_url, pf.precio_consigna, pf.precio_detal, s.stock > 0
    from perfumes pf join stock_efectivo() s on s.perfume_id = pf.id
    where pf.visible_vendedoras and pf.precio_consigna is not null
    order by pf.nombre;
end $$;

-- Anotar un pedido (queda pendiente hasta que lo apruebes)
create or replace function vend_crear_pedido(
  p_token text, p_cliente text, p_telefono text, p_notas text, p_plan text, p_fecha1 date, p_fecha2 date, p_items jsonb
) returns bigint
language plpgsql security definer set search_path = public as $$
declare vid bigint; pid bigint; it jsonb; pf perfumes%rowtype; u int; pv numeric; n int;
begin
  vid := vend_id(p_token);
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 60 then raise exception 'Escribe el nombre del cliente'; end if;
  if coalesce(trim(p_telefono), '') <> '' and char_length(regexp_replace(p_telefono, '\D', '', 'g')) not between 7 and 15 then
    raise exception 'El teléfono no es válido';
  end if;
  if p_plan not in ('contado','mitades','otro') then raise exception 'Elige cómo va a pagar el cliente'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Agrega al menos un perfume';
  end if;
  select count(*) into n from pedidos_vendedora where vendedora_id = vid and estado = 'pendiente';
  if n >= 30 then raise exception 'Tienes muchos pedidos esperando aprobación. Espera a que se revisen.'; end if;

  insert into pedidos_vendedora (vendedora_id, cliente, telefono, notas, plan, fecha1, fecha2)
  values (vid, trim(p_cliente), nullif(trim(p_telefono), ''), nullif(trim(p_notas), ''), p_plan, p_fecha1, p_fecha2)
  returning id into pid;

  for it in select * from jsonb_array_elements(p_items) loop
    u := (it ->> 'unidades')::int; pv := (it ->> 'precio_venta')::numeric;
    if u is null or u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select * into pf from perfumes where id = (it ->> 'perfume_id')::bigint and visible_vendedoras and precio_consigna is not null;
    if not found then raise exception 'Ese perfume ya no está en el catálogo'; end if;
    if pv is null or pv < pf.precio_consigna then
      raise exception 'El precio de % no puede ser menor a $%', pf.nombre, pf.precio_consigna;
    end if;
    insert into pedidos_vendedora_items (pedido_id, perfume_id, unidades, precio_consigna, precio_venta)
    values (pid, pf.id, u, pf.precio_consigna, pv);
  end loop;
  return pid;
end $$;

-- Todos mis pedidos, con lo que gano, lo cobrado y lo que falta
create or replace function vend_mis_pedidos(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare vid bigint;
begin
  vid := vend_id(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'cliente', r.cliente, 'telefono', r.telefono, 'notas', r.notas,
      'plan', r.plan, 'fecha1', r.fecha1, 'fecha2', r.fecha2, 'estado', r.estado, 'nota_admin', r.nota_admin,
      'total_venta', r.total_venta, 'total_consigna', r.total_consigna, 'ganancia', r.ganancia_vendedora, 'ganada', r.ganancia_ganada,
      'cobrado', r.cobrado_cliente, 'falta', greatest(r.total_venta - r.cobrado_cliente, 0),
      'pagado_perfumeria', r.pagado_perfumeria, 'debe_perfumeria', r.debe_perfumeria,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('perfume', pf.nombre, 'unidades', i.unidades,
                  'consigna', i.precio_consigna, 'precio_venta', i.precio_venta) order by i.id), '[]'::jsonb)
                from pedidos_vendedora_items i join perfumes pf on pf.id = i.perfume_id where i.pedido_id = r.id),
      'cobros', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'fecha', c.fecha, 'monto', c.monto, 'quien', c.quien,
                  'nota', c.nota, 'borrable', c.creado > now() - interval '24 hours') order by c.fecha, c.id), '[]'::jsonb)
                from cobros_vendedora c where c.pedido_id = r.id)
    ) order by r.creado desc)
    from vendedora_pedidos_v r where r.vendedora_id = vid), '[]'::jsonb);
end $$;

-- Anotar un cobro del cliente (a quién, cuándo y cuánto)
create or replace function vend_registrar_cobro(p_token text, p_pedido_id bigint, p_fecha date, p_monto numeric, p_quien text, p_nota text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; r vendedora_pedidos_v%rowtype;
begin
  vid := vend_id(p_token);
  select * into r from vendedora_pedidos_v where id = p_pedido_id and vendedora_id = vid;
  if not found then raise exception 'No encuentro ese pedido'; end if;
  if r.estado not in ('aprobado','entregado') then raise exception 'Solo puedes anotar cobros cuando el pedido está aprobado'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'Escribe cuánto te pagaron'; end if;
  if char_length(trim(coalesce(p_quien, ''))) not between 2 and 60 then raise exception 'Escribe quién pagó'; end if;
  if p_fecha is null or p_fecha > (now() at time zone 'America/Caracas')::date + 1 then raise exception 'La fecha no es válida'; end if;
  if p_monto > (r.total_venta - r.cobrado_cliente) + 0.01 then
    raise exception 'Solo faltan $% por cobrar en este pedido', round(r.total_venta - r.cobrado_cliente, 2);
  end if;
  insert into cobros_vendedora (pedido_id, fecha, monto, quien, nota)
  values (p_pedido_id, p_fecha, p_monto, trim(p_quien), nullif(trim(coalesce(p_nota, '')), ''));
  return jsonb_build_object('ok', true);
end $$;

-- Borrar un cobro anotado por error (solo dentro de las primeras 24 horas)
create or replace function vend_borrar_cobro(p_token text, p_cobro_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; n int;
begin
  vid := vend_id(p_token);
  delete from cobros_vendedora c using pedidos_vendedora p
   where c.id = p_cobro_id and p.id = c.pedido_id and p.vendedora_id = vid and c.creado > now() - interval '24 hours';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Ya no se puede borrar ese cobro. Avísale a la perfumería.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Marcar que ya entregó el pedido al cliente
create or replace function vend_marcar_entregado(p_token text, p_pedido_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; n int;
begin
  vid := vend_id(p_token);
  update pedidos_vendedora set estado = 'entregado' where id = p_pedido_id and vendedora_id = vid and estado = 'aprobado';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Ese pedido no se puede marcar como entregado'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 5. Funciones del control (solo socios) ----------
-- Crear o editar una vendedora. El PIN son 6 a 10 números; si lo dejas vacío al editar, no cambia.
create or replace function vend_guardar(p_id bigint, p_nombre text, p_usuario text, p_pin text, p_activa boolean)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nid bigint; usr text := lower(trim(coalesce(p_usuario, ''))); sal text;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  if char_length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre'; end if;
  if usr !~ '^[a-z0-9_]{3,20}$' then raise exception 'El usuario son 3 a 20 letras minúsculas, números o _ (sin espacios)'; end if;
  if coalesce(p_pin, '') <> '' and p_pin !~ '^[0-9]{6,10}$' then raise exception 'El PIN son de 6 a 10 números'; end if;
  if p_id is null then
    if coalesce(p_pin, '') = '' then raise exception 'Pon un PIN de 6 a 10 números'; end if;
    insert into vendedoras (nombre, usuario, activa) values (trim(p_nombre), usr, coalesce(p_activa, true))
    returning id, salt into nid, sal;
    update vendedoras set pin_hash = vend_hash(sal || ':' || p_pin) where id = nid;
  else
    update vendedoras set nombre = trim(p_nombre), usuario = usr, activa = coalesce(p_activa, true),
                          intentos = 0, bloqueado_hasta = null where id = p_id returning id, salt into nid, sal;
    if nid is null then raise exception 'No encuentro esa vendedora'; end if;
    if coalesce(p_pin, '') <> '' then
      update vendedoras set pin_hash = vend_hash(sal || ':' || p_pin) where id = nid;
      delete from vendedora_sesiones where vendedora_id = nid;
    end if;
  end if;
  return nid;
end $$;

-- Aprobar: crea una venta por cada perfume, a precio de CONSIGNACIÓN (lo que ella te debe)
create or replace function vend_aprobar(p_id bigint) returns int
language plpgsql security invoker set search_path = public as $$
declare p pedidos_vendedora%rowtype; d vendedoras%rowtype; it record; tv numeric; vid bigint; ped text; n int := 0; hoy date;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_vendedora where id = p_id for update;
  if not found then raise exception 'No encuentro ese pedido'; end if;
  if p.estado <> 'pendiente' then raise exception 'Ese pedido ya fue revisado'; end if;
  select * into d from vendedoras where id = p.vendedora_id;
  select coalesce(euro, bcv) into tv from tasas order by fecha desc limit 1;
  if tv is null then raise exception 'Primero registra la tasa de hoy en la pestaña Tasas'; end if;
  hoy := (now() at time zone 'America/Caracas')::date;

  for it in select i.*, pf.nombre from pedidos_vendedora_items i join perfumes pf on pf.id = i.perfume_id where i.pedido_id = p.id order by i.id loop
    -- sale del pedido más antiguo con stock suficiente; si no hay, queda como venta anticipada (hay que comprarlo)
    select s.pedido_codigo into ped from stock_pedido_v s
     where s.perfume_id = it.perfume_id and s.restante >= it.unidades order by s.fecha, s.pedido_codigo limit 1;
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values (hoy, p.cliente || ' (vía ' || d.nombre || ')', d.nombre, it.perfume_id, ped, it.unidades, it.precio_consigna, 'divisa', tv, tv,
            coalesce(p.fecha2, p.fecha1),
            'Pedido de vendedora #' || p.id || ': ' || d.nombre || ' lo vende a $' || it.precio_venta || ' c/u y le quedan $' || (it.precio_venta - it.precio_consigna) || ' c/u')
    returning id into vid;
    update pedidos_vendedora_items set venta_id = vid where id = it.id;
    n := n + 1;
  end loop;
  update pedidos_vendedora set estado = 'aprobado', aprobado_por = coalesce(auth.jwt() ->> 'email', ''), aprobado_en = now() where id = p.id;
  return n;
end $$;

create or replace function vend_rechazar(p_id bigint, p_nota text) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  update pedidos_vendedora set estado = 'rechazado', nota_admin = nullif(trim(coalesce(p_nota, '')), ''),
         aprobado_por = coalesce(auth.jwt() ->> 'email', ''), aprobado_en = now()
   where id = p_id and estado = 'pendiente';
  if not found then raise exception 'Ese pedido ya fue revisado'; end if;
end $$;

-- La vendedora te paga: el dinero se aplica a sus ventas más antiguas primero
create or replace function vend_recibir_pago(p_vendedora_id bigint, p_monto numeric, p_cuenta text, p_fecha date) returns numeric
language plpgsql security invoker set search_path = public as $$
declare resto numeric := p_monto; fila record; abono numeric;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'Escribe el monto'; end if;
  if p_cuenta not in ('binance','efectivo') then raise exception 'Elige efectivo o Binance'; end if;
  if p_monto > coalesce((select sum(v.pendiente_usd) from ventas_v v
        where v.id in (select i.venta_id from pedidos_vendedora_items i join pedidos_vendedora p on p.id = i.pedido_id
                        where p.vendedora_id = p_vendedora_id and i.venta_id is not null) and v.pendiente_usd > 0.005), 0) + 0.01 then
    raise exception 'Eso es más de lo que ella te debe';
  end if;
  for fila in select vv.id, vv.pendiente_usd from ventas_v vv
            where vv.id in (select i.venta_id from pedidos_vendedora_items i join pedidos_vendedora p on p.id = i.pedido_id
                             where p.vendedora_id = p_vendedora_id and i.venta_id is not null) and vv.pendiente_usd > 0.005
            order by vv.id loop
    exit when resto <= 0.004;
    abono := least(resto, fila.pendiente_usd);
    insert into cobros (venta_id, fecha, cuenta, monto) values (fila.id, coalesce(p_fecha, current_date), p_cuenta, round(abono, 2));
    resto := resto - abono;
  end loop;
  return p_monto - resto;
end $$;

-- ---------- 6. Permisos ----------
do $$
declare f text;
begin
  -- internas: nadie por la API
  foreach f in array array['stock_efectivo()', 'vend_id(text)', 'vend_hash(text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
  end loop;
  -- la tienda y las vendedoras (anon)
  foreach f in array array['tienda_catalogo()', 'vend_entrar(text,text)', 'vend_catalogo(text)',
      'vend_crear_pedido(text,text,text,text,text,date,date,jsonb)', 'vend_mis_pedidos(text)',
      'vend_registrar_cobro(text,bigint,date,numeric,text,text)', 'vend_borrar_cobro(text,bigint)', 'vend_marcar_entregado(text,bigint)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
  -- el control (solo usuarios con sesión)
  foreach f in array array['vend_guardar(bigint,text,text,text,boolean)', 'vend_aprobar(bigint)', 'vend_rechazar(bigint,text)',
      'vend_recibir_pago(bigint,numeric,text,date)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon', f);
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;
