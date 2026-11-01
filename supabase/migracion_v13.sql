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
