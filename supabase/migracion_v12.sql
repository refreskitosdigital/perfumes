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
