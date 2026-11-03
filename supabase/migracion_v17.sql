-- =====================================================================
-- MIGRACIÓN v17 · Pagos del 2/11 y compra de $50 en Binance
-- Ejecutar DESPUÉS de migracion_v16.sql. Se aplica UNA sola vez aunque la repitas.
--  Cobros (fecha 2/11):
--   Wuile Kyomu · Starwalker           $13 efectivo (queda $2)
--   María Fernanda Kyomu · Amber Rouge + Splash   44.606,42 Bs a tasa 991,25 = $45 (le queda La Bomba $35)
--   Jesus Zapatero · Mandarin Sky Elixir          12.400 Bs a 992 = $12,50
--   Elvys Castillo · Victorinox                   24.850 Bs contados como $25 (pagó completo)
--   Wuile Kyomu · Bestia Negra                    13.902 Bs a 992 = $14,01
--   Carola Carvajal · Mandarin Elixir + Yara Tous 35.600 Bs contados como $40 ($30 y $10)
--  Compra de divisa: 50.058,42 Bs (44.100 + 5.958,42) por $50 en Binance.
--  Caja resultante: efectivo $80, Binance $126, banco 83.900 Bs.
-- =====================================================================
do $$
declare
  r record; v_id bigint; bcv_ref numeric; tb numeric; cta text; delta numeric;
  t_ef constant numeric := 80; t_bin constant numeric := 126; t_bs constant numeric := 83900;
begin
  if exists (select 1 from cargas_hechas where clave = 'v17_pagos_2nov') then
    raise notice 'La v17 ya estaba aplicada. No se repite.'; return;
  end if;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  for r in select * from (values
      ('wuile kyomu',          'starwalker',  'efectivo', 13::numeric,   null::numeric),
      ('maría fernanda kyomu', 'amber rouge', 'bs',       34693.22,      991.2538),
      ('maría fernanda kyomu', 'splash',      'bs',       9913.20,       991.2538),
      ('jesus zapatero',       'mandarin sky elixir', 'bs', 12400,       992),
      ('elvys castillo',       'victorinox',  'bs',       24850,         994),
      ('wuile kyomu',          'bestia negra','bs',       13902,         992),
      ('carola carvajal',      'mandarin sky elixir', 'bs', 26700,       890),
      ('carola carvajal',      'yara tous',   'bs',       8900,          890)
    ) as t(cliente, perfume, cuenta, monto, tasa)
  loop
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) = norm_txt(r.cliente) and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%'
       and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%" para "%". No se aplicó nada.', r.cliente, r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-02', r.cuenta, r.monto, r.tasa);
  end loop;

  -- Compra de $50 en Binance con 50.058,42 Bs
  insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
  values ('2026-11-02', 50058.42, 50, 'binance', coalesce(bcv_ref, tb), 'Compra de $50 en Binance: 44.100 Bs + 5.958,42 Bs');

  -- Si la caja no queda exactamente en el conteo real, la diferencia se anota aparte (inciso)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-02', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de las ventas registradas'
                   else 'Faltante por conciliar: la caja real es menor a lo que muestran las ventas' end, true);
      raise notice 'Ajuste de conciliación en %: %', cta, round(delta, 2);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v17_pagos_2nov');
end $$;
