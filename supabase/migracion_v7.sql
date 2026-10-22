-- =====================================================================
-- MIGRACIÓN V7 · La tienda muestra TODOS los perfumes.
-- Antes solo salían los que tenían "precio al detal" cargado, por eso faltaban los
-- demás. Ahora salen todos (con foto a color, haya o no stock). Los que todavía no
-- tienen precio salen como "Precio por confirmar" y se pueden agendar, pero no se
-- compran online hasta que les pongas precio en Inventario.
-- NO modifica ni borra nada de lo que ya cargaste.
-- Ejecútala UNA VEZ después de migracion_v6.sql. Es segura de repetir.
-- =====================================================================
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         greatest(coalesce(c.u, 0) - coalesce(v.u, 0) - coalesce(w.u, 0), 0)::int,
         pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.nombre;
$$;

-- Un perfume sin precio no se puede comprar online (solo agendar)
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
    if pu is null then raise exception 'Ese perfume todavía no tiene precio: agéndalo y te avisamos'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;
