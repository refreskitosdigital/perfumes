-- =====================================================================
-- MIGRACIÓN v19 · El almuerzo del 2/11 se pagó del banco (Bs)
-- Ejecutar DESPUÉS de migracion_v18.sql. Se aplica UNA sola vez.
-- 32.022 Bs a tasa BCV $ 891,10 salen de la caja en bolívares: 16.011 Bs a cargo de Juan y 16.011 Bs a cargo de George ($17,97 cada uno).
-- Rosanny no se afecta. Se quita el gasto del almuerzo de la v18 para no descontarlo dos veces.
-- =====================================================================
do $$
begin
  if exists (select 1 from cargas_hechas where clave = 'v19_almuerzo_banco') then
    raise notice 'La v19 ya estaba aplicada. No se repite.'; return;
  end if;

  delete from gastos where concepto like 'Almuerzo de Juan y George%';

  insert into retiros_socios (fecha, socio, tipo, cuenta, monto, tasa, monto_usd, nota)
  select '2026-11-02', s, 'otro', 'bs', 16011, 891.10, round(16011 / 891.10, 2),
         'Almuerzo de Juan y George: 32.022 Bs a tasa BCV $ 891,10 (mitad cada uno)'
  from unnest(array['Juan','George']) s;

  insert into cargas_hechas (clave) values ('v19_almuerzo_banco');
end $$;
