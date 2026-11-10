-- =====================================================================
-- MIGRACIÓN v24 · Pagos del 6/11 y del 9/11
-- Ejecutar DESPUÉS de migracion_v23.sql. Se aplica UNA sola vez aunque la repitas.
-- Cada pago se aplica a las ventas más antiguas del cliente que tengan saldo.
-- Se cuentan los $ dichos; la tasa guardada es Bs ÷ $ (igual que en v17 y v20).
--   6/11  Hijo del Carpintero  13.410 Bs = $15 (BCV $ 894)
--   (Luisa Teran, 17.500 Bs = $20, queda aparte: solo debía $15)
--   6/11  Jessica Green Hair   26.910 Bs = $30 (BCV $ 897)
--   6/11  Yeimy Green Hair     $30 en efectivo
--   9/11  Jesus Zapatero       12.514 Bs = $12,50 (BCV $ 897,53)
-- =====================================================================
do $$
declare
  r record; s record; resto numeric; aplica numeric;
begin
  if exists (select 1 from cargas_hechas where clave = 'v24_pagos_6_9nov') then
    raise notice 'La v24 ya estaba aplicada. No se repite.'; return;
  end if;

  for r in select * from (values
      ('2026-11-06'::date, 'hijo del carpintero', 'bs',       13410::numeric,  15::numeric),
      ('2026-11-06',       'jessica green hair',  'bs',       26910,           30),
      ('2026-11-06',       'yeimy green hair',    'efectivo', 30,              30),
      ('2026-11-09',       'jesus zapatero',      'bs',       12514,           12.50)
    ) as t(fecha, cliente, cuenta, monto, usd)
  loop
    resto := r.usd;
    for s in select v.id, v.pendiente_usd from ventas_v v
              where norm_txt(v.cliente) = norm_txt(r.cliente) and v.pendiente_usd > 0.01 order by v.fecha, v.id loop
      exit when resto <= 0.005;
      aplica := least(resto, s.pendiente_usd);
      insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
      values (s.id, r.fecha, r.cuenta,
              case when r.cuenta = 'bs' then round(r.monto * aplica / r.usd, 2) else round(aplica, 2) end,
              case when r.cuenta = 'bs' then round(r.monto / r.usd, 4) end);
      resto := resto - aplica;
    end loop;
    if resto > 0.01 then raise exception 'A "%" le sobran $% sin venta con saldo. No se aplicó nada.', r.cliente, round(resto, 2); end if;
  end loop;

  insert into cargas_hechas (clave) values ('v24_pagos_6_9nov');
end $$;
