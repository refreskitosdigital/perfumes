-- =====================================================================
-- MIGRACIÓN V4 · Tienda online (pedidos web, perfumes agotados "Agendar pedido",
-- ajustes de la tienda y fotos). Se ejecuta UNA VEZ en el SQL Editor,
-- después de migracion_v3.sql. Es segura de repetir.
-- =====================================================================

-- ---------- Perfumes: foto y visibilidad en la tienda ----------
alter table perfumes add column if not exists foto_url text;
alter table perfumes add column if not exists visible_tienda boolean not null default true;

-- ---------- Ajustes de la tienda (los edita un socio desde la app) ----------
create table if not exists tienda_config (
  id int primary key default 1 check (id = 1),
  nombre text not null default 'Perfumes',
  whatsapp text,                                   -- número que recibe los pedidos, con código de país (ej. 584141234567)
  umbral_mayor int not null default 12,            -- perfumes en el carrito para el precio al mayor
  mensaje text,                                    -- frase corta bajo el título
  metodos jsonb not null default '[]'::jsonb       -- [{"titulo":"Pago móvil","detalle":"..."}]
);
insert into tienda_config (id, mensaje, metodos) values (
  1, 'Perfumes árabes y de diseñador, listos para entrega.',
  '[{"titulo":"Pago móvil / transferencia en Bs","detalle":"Te enviamos los datos por WhatsApp al confirmar."},
    {"titulo":"Efectivo en dólares","detalle":"Al momento de la entrega."},
    {"titulo":"Binance (USDT)","detalle":"Te enviamos el ID por WhatsApp al confirmar."}]'::jsonb
) on conflict (id) do nothing;

-- ---------- Pedidos que llegan desde la tienda ----------
create sequence if not exists pedido_web_seq;
create table if not exists pedidos_web (
  id bigint generated always as identity primary key,
  codigo text unique not null default ('W-' || lpad(nextval('pedido_web_seq')::text, 3, '0')),
  creado timestamptz not null default now(),
  cliente text not null,
  telefono text not null,
  notas text,
  metodo_pago text,
  mayor boolean not null default false,
  total_usd numeric not null,
  tasa_bcv numeric,
  tasa_binance numeric,
  estado text not null default 'nuevo' check (estado in ('nuevo','confirmado','cancelado')),
  atendido_por text,
  atendido date
);
create table if not exists pedidos_web_items (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_web(id) on delete cascade,
  perfume_id bigint not null references perfumes(id),
  unidades int not null check (unidades > 0),
  precio_unit numeric not null check (precio_unit >= 0)
);

-- ---------- Perfumes agotados que la gente quiere (sirve para decidir qué comprar) ----------
create table if not exists demanda_web (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  perfume_id bigint not null references perfumes(id) on delete cascade,
  cliente text not null,
  telefono text not null,
  unidades int not null default 1 check (unidades > 0),
  atendido boolean not null default false
);

-- ---------- Seguridad: las tablas solo las ven los socios ----------
do $$
declare t text;
begin
  foreach t in array array['tienda_config','pedidos_web','pedidos_web_items','demanda_web'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
  end loop;
end $$;

-- =====================================================================
-- FUNCIONES PÚBLICAS (las usa la tienda sin iniciar sesión).
-- Solo devuelven lo que se puede mostrar: nombre, precio, disponibilidad y foto.
-- Nunca costos, ganancias, clientes ni deudas.
-- =====================================================================

-- Unidades disponibles para la tienda = compradas − vendidas − apartadas por pedidos web nuevos
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int, foto_url text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         greatest(coalesce(c.u, 0) - coalesce(v.u, 0) - coalesce(w.u, 0), 0)::int,
         pf.foto_url
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id
  where pf.visible_tienda and pf.precio_detal is not null
  order by pf.nombre;
$$;

create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'tasa', (select to_jsonb(t) from (select fecha, bcv, binance from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

-- Crear un pedido desde la tienda. Los precios se calculan aquí (el navegador no puede cambiarlos).
create or replace function tienda_crear_pedido(
  p_cliente text, p_telefono text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int;
begin
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 80 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);          -- evita que dos personas aparten la misma última unidad
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;

  select bcv, binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance)
  values (trim(p_cliente), trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance)
  returning id, codigo into pid, ped_codigo;

  for it in select * from jsonb_array_elements(agg) loop
    pf := (it ->> 'perfume_id')::bigint; u := (it ->> 'unidades')::int;
    if u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select c.stock, case when mayor then c.precio_mayor else c.precio_detal end
      into disp, pu from tienda_catalogo() c where c.id = pf;
    if disp is null then raise exception 'Ese perfume ya no está disponible'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;

-- "Agendar pedido" de un perfume agotado: queda como demanda, no aparta ni cobra nada
create or replace function tienda_agendar(p_perfume_id bigint, p_cliente text, p_telefono text, p_unidades int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 80 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if coalesce(p_unidades, 0) not between 1 and 60 then raise exception 'Cantidad no válida'; end if;
  if not exists (select 1 from perfumes where id = p_perfume_id and visible_tienda) then raise exception 'Ese perfume no existe'; end if;
  -- evita duplicados del mismo teléfono para el mismo perfume pendiente
  if exists (select 1 from demanda_web where perfume_id = p_perfume_id and not atendido
             and regexp_replace(telefono, '\D', '', 'g') = regexp_replace(p_telefono, '\D', '', 'g')) then
    update demanda_web set unidades = p_unidades, cliente = trim(p_cliente)
    where perfume_id = p_perfume_id and not atendido and regexp_replace(telefono, '\D', '', 'g') = regexp_replace(p_telefono, '\D', '', 'g');
  else
    insert into demanda_web (perfume_id, cliente, telefono, unidades) values (p_perfume_id, trim(p_cliente), trim(p_telefono), p_unidades);
  end if;
end $$;

-- Permisos: la tienda (rol anon) solo puede ejecutar estas funciones
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'tienda_info()',
      'tienda_crear_pedido(text,text,text,text,jsonb)', 'tienda_agendar(bigint,text,text,int)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- =====================================================================
-- FUNCIONES DE LOS SOCIOS
-- =====================================================================

-- Confirmar un pedido web: lo convierte en ventas (sale del pedido más antiguo con stock) y aparecen en Por cobrar
create or replace function confirmar_pedido_web(p_id bigint, p_vendedor text) returns text
language plpgsql security invoker set search_path = public as $$
declare
  p pedidos_web%rowtype; it record; s record; falta int; toma int;
  tb numeric; tn numeric;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  if coalesce(trim(p_vendedor), '') = '' then raise exception 'Elige quién atiende el pedido'; end if;
  select bcv, binance into tb, tn from tasas order by fecha desc limit 1;
  tb := coalesce(p.tasa_bcv, tb); tn := coalesce(p.tasa_binance, tn);
  if tb is null or tn is null then raise exception 'Registra primero la tasa del día'; end if;

  for it in select * from pedidos_web_items where pedido_id = p.id order by id loop
    falta := it.unidades;
    for s in select pedido_codigo, restante from stock_pedido_v
             where perfume_id = it.perfume_id and restante > 0 order by fecha, pedido_codigo loop
      exit when falta <= 0;
      toma := least(falta, s.restante);
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, s.pedido_codigo, toma, it.precio_unit, 'divisa', tb, tn, 'Pedido web ' || p.codigo);
      falta := falta - toma;
    end loop;
    if falta > 0 then   -- sin stock en los pedidos: queda como venta anticipada
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, null, falta, it.precio_unit, 'divisa', tb, tn, 'Pedido web ' || p.codigo);
    end if;
  end loop;

  update clientes set telefono = p.telefono
  where lower(trim(nombre)) = lower(trim(p.cliente)) and coalesce(telefono, '') = '';
  update pedidos_web set estado = 'confirmado', atendido_por = p_vendedor, atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- Cancelar un pedido web: las unidades vuelven a estar disponibles en la tienda
create or replace function cancelar_pedido_web(p_id bigint) returns text
language plpgsql security invoker set search_path = public as $$
declare p pedidos_web%rowtype;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  update pedidos_web set estado = 'cancelado', atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- =====================================================================
-- FOTOS: carpeta pública "perfumes" en Supabase Storage (solo los socios pueden subir)
-- =====================================================================
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public) values ('perfumes', 'perfumes', true) on conflict (id) do nothing;
    execute 'drop policy if exists fotos_ver on storage.objects';
    execute 'drop policy if exists fotos_subir on storage.objects';
    execute 'drop policy if exists fotos_cambiar on storage.objects';
    execute 'drop policy if exists fotos_borrar on storage.objects';
    execute $p$create policy fotos_ver on storage.objects for select using (bucket_id = 'perfumes')$p$;
    execute $p$create policy fotos_subir on storage.objects for insert to authenticated with check (bucket_id = 'perfumes' and public.es_socio())$p$;
    execute $p$create policy fotos_cambiar on storage.objects for update to authenticated using (bucket_id = 'perfumes' and public.es_socio())$p$;
    execute $p$create policy fotos_borrar on storage.objects for delete to authenticated using (bucket_id = 'perfumes' and public.es_socio())$p$;
  end if;
end $$;
