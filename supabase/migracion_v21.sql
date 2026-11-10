-- =====================================================================
-- MIGRACIÓN v21 · Compras de divisa y de perfumes del 5/11, cobros de Kyuran y Jean Mary, cuadre de caja
-- Ejecutar DESPUÉS de migracion_v20.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Pago a Refreskitos (Juan) del 2/11: 29.760 Bs a tasa 992 = $30 (solo si no lo habías anotado ya).
--  2. Compras de divisa con bolívares (5/11): $30 a Binance (30.000 Bs) y $20 + $30 + $15 en efectivo (20.000 + 30.000 + 15.000 Bs), a 1.000 Bs por $.
--  3. Compra de perfumes para el P-005: 212 VIP Rose + Odyssey Home nuevo, $13,50 cada uno = $27 (27.351 Bs del banco).
--     El aporte del P-005 sube de $13,50 a $27 ($9 cada socio).
--  4. Kyuran paga $40 por Binance (Lacoste $30 + splash $10). Pagó $50: los $10 de vuelto se le dieron en Bs (10.000 Bs a 1.000).
--  5. Jean Mary de la Hoz abona $60 por Binance a sus ventas más antiguas con saldo.
--  6. Cuadre al conteo real: efectivo $165, Binance $216, banco 41.297 Bs. Cualquier diferencia se anota aparte
--     como "Sobrante/Faltante por conciliar" (inciso), sin tocar lo demás.
-- =====================================================================
do $$
declare
  r record; v_id bigint; v_perf bigint; bcv_ref numeric; tb numeric; cta text; delta numeric; resto numeric; aplica numeric;
  t_ef constant numeric := 165; t_bin constant numeric := 216; t_bs constant numeric := 41297;
begin
  if exists (select 1 from cargas_hechas where clave = 'v21_compras_5nov') then
    raise notice 'La v21 ya estaba aplicada. No se repite.'; return;
  end if;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  -- 1. Pago a Juan (si no estaba)
  insert into retiros_socios (fecha, socio, tipo, cuenta, monto, tasa, monto_usd, nota)
  select '2026-11-02', 'Juan', 'reparto', 'bs', 29760, 992, 30, 'Pago a Refreskitos: 29.760 Bs a tasa 992 = $30'
  where not exists (select 1 from retiros_socios where fecha = '2026-11-02' and socio = 'Juan' and monto = 29760);

  -- 2. Compras de divisa
  insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota) values
    ('2026-11-05', 30000, 30, 'binance',  coalesce(bcv_ref, tb), 'Compra de $30 en Binance a 1.000'),
    ('2026-11-05', 20000, 20, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $20 en efectivo a Rosangela a 1.000'),
    ('2026-11-05', 30000, 30, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $30 en efectivo a 1.000'),
    ('2026-11-05', 15000, 15, 'efectivo', coalesce(bcv_ref, tb), 'Compra de $15 en efectivo a 1.000');

  -- 3. Perfumes del P-005 (212 VIP Rose ya está) + Odyssey Home nuevo
  insert into perfumes (nombre) values ('Odyssey Home') on conflict do nothing;
  select id into v_perf from perfumes where lower(trim(nombre)) = 'odyssey home';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario) values ('P-005', v_perf, 1, 13.50);
  update pedido_socios set aporte = 9 where pedido_codigo = 'P-005';
  insert into movimientos (fecha, cuenta, monto, nota)
  values ('2026-11-05', 'bs', -27351, 'Compra de perfumes P-005: 212 VIP Rose + Odyssey Home ($27 a $13,50 c/u)');

  -- 4. Kyuran: $40 por Binance y $10 de vuelto en Bs
  for r in select * from (values ('lacoste white', 30::numeric), ('splash', 10::numeric)) as t(perfume, usd) loop
    v_id := null;
    select v.id into v_id from ventas_v v
     where norm_txt(v.cliente) = 'kyuran' and norm_txt(v.nombre) like '%' || norm_txt(r.perfume) || '%' and v.pendiente_usd > 0.01
     order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de Kyuran (%). No se aplicó nada.', r.perfume; end if;
    insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-05', 'binance', r.usd);
  end loop;
  insert into movimientos (fecha, cuenta, monto, nota) values
    ('2026-11-05', 'binance', 10, 'Kyuran pagó $50 por Binance y debía $40: $10 de vuelto'),
    ('2026-11-05', 'bs', -10000, 'Vuelto a Kyuran: $10 en Bs a 1.000');

  -- 5. Jean Mary de la Hoz: $60 a sus ventas más antiguas con saldo
  resto := 60;
  for r in select v.id, v.pendiente_usd from ventas_v v
            where norm_txt(v.cliente) like norm_txt('jean mary') || '%' and v.pendiente_usd > 0.01 order by v.fecha, v.id loop
    exit when resto <= 0.005;
    aplica := least(resto, r.pendiente_usd);
    insert into cobros (venta_id, fecha, cuenta, monto) values (r.id, '2026-11-05', 'binance', round(aplica, 2));
    resto := resto - aplica;
  end loop;
  if resto > 0.01 then raise exception 'A Jean Mary de la Hoz le sobran $% sin venta con saldo. No se aplicó nada.', round(resto, 2); end if;

  -- 6. Cuadre al conteo real (la diferencia queda como inciso aparte)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-05', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de lo registrado'
                   else 'Faltante por conciliar: la caja real es menor a lo registrado' end, true);
      raise notice 'Ajuste de conciliación en %: %', cta, round(delta, 2);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v21_compras_5nov');
end $$;
