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
