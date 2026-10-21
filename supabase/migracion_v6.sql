-- =====================================================================
-- MIGRACIÓN V6 · Una sola tasa de venta: BCV Euro.
--  · La tasa BCV Euro (Bs por €) es la que ven los clientes en la tienda y la que usan
--    las ventas nuevas para convertir $ <-> Bs.
--  · La tasa Binance queda SOLO como dato interno (valorar la caja y comprar divisas
--    para recomprar mercancía). La tienda pública ya no la recibe.
--  · Ya no se pide el dólar BCV. Las filas antiguas se conservan.
-- Ejecútala UNA VEZ después de migracion_v5.sql. Es segura de repetir.
-- =====================================================================
alter table tasas add column if not exists euro numeric check (euro > 0);
alter table tasas alter column bcv drop not null;

-- La tienda solo recibe la tasa de venta (BCV Euro); nunca la Binance
create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'banners', coalesce((select jsonb_agg(b.url order by b.orden) from tienda_banners b where b.activo), '[]'::jsonb),
    'tasa', (select to_jsonb(t) from (select fecha, coalesce(euro, bcv) as euro from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

-- Pedidos web: guardan la tasa de venta (BCV Euro) con la que se cotizó
create or replace function tienda_crear_pedido(
  p_nombre text, p_apellido text, p_telefono text, p_ubicacion text,
  p_delivery boolean, p_entrega text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int; cli text;
begin
  if char_length(trim(coalesce(p_nombre, ''))) not between 2 and 40 then raise exception 'Escribe tu nombre'; end if;
  if char_length(trim(coalesce(p_apellido, ''))) not between 2 and 40 then raise exception 'Escribe tu apellido'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if char_length(trim(coalesce(p_ubicacion, ''))) not between 3 and 120 then raise exception 'Cuéntanos en qué zona o ciudad te encuentras'; end if;
  if coalesce(p_delivery, false) and char_length(trim(coalesce(p_entrega, ''))) not between 3 and 200 then
    raise exception 'Escribe hasta dónde necesitas el delivery';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;
  cli := trim(p_nombre) || ' ' || trim(p_apellido);

  select coalesce(euro, bcv) as bcv, coalesce(euro, bcv) as binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance, ubicacion, delivery, entrega_en)
  values (cli, trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance,
          trim(p_ubicacion), coalesce(p_delivery, false), case when coalesce(p_delivery, false) then trim(p_entrega) end)
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


-- Confirmar pedido web: las ventas usan la tasa de venta guardada en el pedido
create or replace function confirmar_pedido_web(p_id bigint, p_vendedor text) returns text
language plpgsql security invoker set search_path = public as $$
declare
  p pedidos_web%rowtype; it record; s record; falta int; toma int;
  tb numeric; tn numeric; nota text;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  if coalesce(trim(p_vendedor), '') = '' then raise exception 'Elige quién atiende el pedido'; end if;
  select coalesce(euro, bcv), coalesce(euro, bcv) into tb, tn from tasas order by fecha desc limit 1;
  tb := coalesce(p.tasa_bcv, tb); tn := coalesce(p.tasa_binance, tn);
  if tb is null or tn is null then raise exception 'Registra primero la tasa del día'; end if;
  nota := 'Pedido web ' || p.codigo || case when p.delivery then ' · Delivery: ' || coalesce(p.entrega_en, '') else '' end;

  for it in select * from pedidos_web_items where pedido_id = p.id order by id loop
    falta := it.unidades;
    for s in select pedido_codigo, restante from stock_pedido_v
             where perfume_id = it.perfume_id and restante > 0 order by fecha, pedido_codigo loop
      exit when falta <= 0;
      toma := least(falta, s.restante);
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, s.pedido_codigo, toma, it.precio_unit, 'divisa', tb, tn, nota);
      falta := falta - toma;
    end loop;
    if falta > 0 then
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, null, falta, it.precio_unit, 'divisa', tb, tn, nota);
    end if;
  end loop;

  update clientes set telefono = p.telefono
  where lower(trim(nombre)) = lower(trim(p.cliente)) and coalesce(telefono, '') = '';
  update pedidos_web set estado = 'confirmado', atendido_por = p_vendedor, atendido = current_date where id = p.id;
  return p.codigo;
end $$;
