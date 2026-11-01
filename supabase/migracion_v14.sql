-- =====================================================================
-- MIGRACIÓN v14 · Todo en dólares, tasa BCV en cada cobro en Bs, merma por pedido y datos del 1/11
-- Ejecutar DESPUÉS de migracion_v13.sql. Las partes de CARGA se aplican una sola vez.
--
--  1. cobros.tasa_bcv: la tasa BCV a la que pagó el cliente en Bs. Los cobros viejos se completan solos.
--  2. Las ventas valen su monto en dólares ($35 son $35). Un cobro en Bs vale Bs ÷ tasa BCV pagada.
--  3. merma_cobros_v / merma_pedido_v: lo que se pierde por la brecha en cada cobro en Bs y por pedido
--     (BCV pagada contra Binance del día del cobro).
--  4. Datos: pago del lote 4 desde la caja ($345 efectivo), taxi $11, cobro de Eduin Torres,
--     segunda venta del Thank U Next y corrección del splash (eran 9, no 10, en el pedido 3).
-- =====================================================================

-- ---------- 1. Tasa BCV en cada cobro ----------
alter table cobros add column if not exists tasa_bcv numeric;
update cobros co set tasa_bcv = coalesce(co.tasa_binance, v.tasa_bcv)
from ventas v where v.id = co.venta_id and co.cuenta = 'bs' and co.tasa_bcv is null;

-- ---------- 2. Ventas en dólares nominales ----------
create or replace view ventas_v with (security_invoker = true) as
select x.*,
       x.valor_usd - x.cobrado_usd as pendiente_usd,
       x.costo_unit * x.unidades as costo_total,
       case when x.costo_unit is null then null else x.valor_usd - x.costo_unit * x.unidades end as ganancia
from (
  select v.*, pf.sku, pf.nombre,
         v.unidades * v.precio_unit as total_pactado,
         v.unidades * v.precio_unit as valor_usd,
         coalesce((select sum(case when co.cuenta = 'bs' then co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) else co.monto end)
                   from cobros co where co.venta_id = v.id), 0) as cobrado_usd,
         (select cp.costo_real from costos_pedido_v cp
           where cp.pedido_codigo = v.pedido_codigo and cp.perfume_id = v.perfume_id) as costo_unit
  from ventas v join perfumes pf on pf.id = v.perfume_id
) x;

-- ---------- 3. Merma por cobro en Bs y por pedido ----------
create or replace function binance_del_dia(p_fecha date) returns numeric
language sql stable as $f$
  select coalesce(
    (select binance from tasas where fecha <= p_fecha order by fecha desc limit 1),
    (select binance from tasas order by fecha limit 1))
$f$;

create or replace view merma_cobros_v with (security_invoker = true) as
select co.id as cobro_id, co.fecha, v.pedido_codigo, v.cliente, co.monto as bs,
       coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) as tasa_bcv,
       binance_del_dia(co.fecha::date) as binance_dia,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv), 2) as nominal_usd,
       round(co.monto / binance_del_dia(co.fecha::date), 2) as real_usd,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) - co.monto / binance_del_dia(co.fecha::date), 2) as merma_usd
from cobros co join ventas v on v.id = co.venta_id
where co.cuenta = 'bs';

create or replace view merma_pedido_v with (security_invoker = true) as
select coalesce(pedido_codigo, 'Sin pedido') as pedido_codigo,
       count(*)::int as cobros_bs, round(sum(bs), 2) as bs,
       round(sum(nominal_usd), 2) as nominal_usd, round(sum(real_usd), 2) as real_usd,
       round(sum(merma_usd), 2) as merma_usd
from merma_cobros_v group by 1;

-- ---------- 4. Datos del 30/10 al 1/11 (una sola vez) ----------
do $$
declare tv numeric; tb numeric; v_id bigint; pid bigint; ok_spl int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v14_datos_1nov') then
    raise notice 'Los datos de v14 ya estaban cargados. No se repiten.'; return;
  end if;
  select coalesce(euro, bcv), binance into tv, tb from tasas order by fecha desc limit 1;
  if coalesce(tv, 0) <= 0 or coalesce(tb, 0) <= 0 then
    raise exception 'Primero guarda en "Finanzas > Tasas" la tasa de hoy (BCV $, BCV Euro y Binance) y vuelve a ejecutar esto.';
  end if;

  -- Lote 4: pagado con la caja ($345 en efectivo)
  insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', -345, 'Pago del lote 4 (P-004) con la caja');

  -- Taxi para transportar los perfumes (sale de la caja, en efectivo)
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  values ('2026-10-30', 'traslado', 'Taxi para transportar los perfumes', 11, 'P-004', 'efectivo', 'Juan');

  -- Eduin Torres pagó sus $15 en Bs a BCV 994  ->  14.910 Bs
  select v.id into v_id from ventas_v v where lower(v.cliente) like 'eduin torre%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Eduin Torres.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-01', 'bs', 15 * 994, 994);

  -- Thank U Next: la segunda unidad también se la vendió a Keylin Cabrera por $25 en efectivo
  select id into pid from perfumes where lower(trim(nombre)) = 'ariana grande thank u next';
  if pid is null then raise exception 'No encuentro el perfume Ariana Grande Thank U Next.'; end if;
  insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
  values ('2026-10-30', 'Keylin Cabrera', 'Juan', pid, 'P-003', 1, 25, 'divisa', tv, tb, 'Segunda unidad del Thank U Next. Pagó en efectivo')
  returning id into v_id;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-30', 'efectivo', 25);

  -- Splash: en el pedido 3 llegaron 9 (no 10) por los mismos $26 en total
  update compras set unidades = 9, costo_unitario = round(26.0 / 9, 4)
   where pedido_codigo = 'P-003'
     and perfume_id = (select id from perfumes where nombre ilike 'Victoria Secret Splash%' order by id limit 1)
     and unidades = 10;
  get diagnostics ok_spl = row_count;
  if ok_spl = 0 then raise notice 'REVISAR: no encontré 10 splash en el pedido 3; corrige el splash a mano en Inventario.'; end if;

  insert into cargas_hechas (clave) values ('v14_datos_1nov');
end $$;

-- ---------- Permisos ----------
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function binance_del_dia(date) to authenticated;
  end if;
end $$;
