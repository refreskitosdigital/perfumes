-- Cobros del 30/10 (se aplica una sola vez aunque lo repitas)
--  · Anny Guitian: $7,50 de los splash que faltaban, pagados en Bs a BCV $ 888  -> 6.660 Bs
--  · Wuile Kyomu (Wuilesmar): $7 de su splash, pagados en Bs a BCV Euro 993    -> 6.951 Bs
do $$
declare v_id bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'cobros_30oct_splash') then
    raise notice 'Estos cobros ya estaban registrados. No se repite.'; return;
  end if;

  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'anny guitian%' and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise exception 'No encontré la venta de splash de Anny Guitian.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance) values (v_id, '2026-10-30', 'bs', round(7.5 * 888, 2), 888);

  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where (lower(v.cliente) like 'wuile%' ) and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise exception 'No encontré la venta de splash de Wuilesmar (Wuile Kyomu).'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance) values (v_id, '2026-10-30', 'bs', round(7 * 993, 2), 993);

  insert into cargas_hechas (clave) values ('cobros_30oct_splash');
end $$;
