-- =====================================================================
-- MIGRACIÓN v20 · Pagos del 3/11 y del 5/11 + venta nueva de 212 VIP Rose a Johenis
-- Ejecutar DESPUÉS de migracion_v19.sql. Se aplica UNA sola vez aunque la repitas.
--  Venta nueva: Carolina Herrera 212 VIP Rose Fem a Johenis Canguro, $25 (costo $13,50, comprada el 5/11 en el pedido P-005).
--  Cobros (se cuentan los $ dichos; la tasa guardada es Bs ÷ $, igual que en la v17):
--   3/11  Johenis Canguro   11.975 Bs  = $12,50 (mitad del 212 VIP Rose, tasa euro 991,25)
--   3/11  María Fernanda Kyomu  34.927,28 Bs = $35 (La Bomba, tasa euro 991,25)
--   3/11  Rosanny Cequea    13.350 Bs  = $15 (splash, BCV $ 889)
--   5/11  Carlos Gonzales (Wuile)  12.575,41 Bs = $12,50 (mitad, tasa euro 1.000)
--   5/11  Veronica          $20 en efectivo (212 VIP Rose Fem)
--   5/11  Lori Teran        25.150,82 Bs = $25 (Mod Blush, tasa 1.000)
--   5/11  Rosalba Guitian   13.423,31 Bs = $15 (Good Girl, BCV $ 894)
-- =====================================================================
do $$
declare
  r record; v_id bigint; v_perf bigint; tb numeric; tbcv numeric;
begin
  if exists (select 1 from cargas_hechas where clave = 'v20_pagos_3_5nov') then
    raise notice 'La v20 ya estaba aplicada. No se repite.'; return;
  end if;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  select bcv into tbcv from tasas where bcv > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  -- ---------- Pedido P-005: 1 unidad de 212 VIP Rose Fem a $13,50 (comprada el 5/11) ----------
  select id into v_perf from perfumes
   where norm_txt(nombre) = norm_txt('Carolina Herrera 212 VIP Rose Fem')
      or norm_txt(nombre) like '%212 vip rose%' order by id limit 1;
  if v_perf is null then raise exception 'No encontré el perfume 212 VIP Rose en el catálogo.'; end if;

  insert into pedidos (codigo, fecha, proveedor, envio) values ('P-005', '2026-11-05', null, 0) on conflict do nothing;
  insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
    ('P-005', 'Juan', 4.50, 1.0/3), ('P-005', 'George', 4.50, 1.0/3), ('P-005', 'Rosanny', 4.50, 1.0/3)
  on conflict do nothing;
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario) values ('P-005', v_perf, 1, 13.50);

  -- ---------- Venta a Johenis Canguro (3/11) ----------
  insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance)
  values ('2026-11-03', 'Johenis Canguro', 'Juan', v_perf, 'P-005', 1, 25, 'divisa',
          coalesce((select bcv from tasas where fecha <= '2026-11-03' and bcv > 0 order by fecha desc limit 1), tbcv, tb),
          coalesce((select binance from tasas where fecha <= '2026-11-03' and binance > 0 order by fecha desc limit 1), tb));

  -- ---------- Cobros ----------
  for r in select * from (values
      ('2026-11-03'::date, 'johenis canguro',         '212 vip rose',  'bs',       11975::numeric,  12.50::numeric),
      ('2026-11-03',       'maría fernanda kyomu',    'bomba',         'bs',       34927.28,        35),
      ('2026-11-03',       'rosanny cequea',          'splash',        'bs',       13350,           15),
      ('2026-11-05',       'carlos gonzales',         '',              'bs',       12575.41,        12.50),
      ('2026-11-05',       'veronica',                '212 vip rose',  'efectivo', 20,              20),
      ('2026-11-05',       'lori teran',              'mod blush',     'bs',       25150.82,        25),
      ('2026-11-05',       'rosalba guitian',         'good girl',     'bs',       13423.31,        15)
    ) as t(fecha, cliente, perfume, cuenta, monto, usd)
  loop
    v_id := null;
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) like norm_txt(r.cliente) || '%' and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%'
       and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%" (%). No se aplicó nada.', r.cliente, r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
    values (v_id, r.fecha, r.cuenta, r.monto, case when r.cuenta = 'bs' then round(r.monto / r.usd, 4) end);
  end loop;

  insert into cargas_hechas (clave) values ('v20_pagos_3_5nov');
end $$;
