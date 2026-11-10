-- =====================================================================
-- MIGRACIÓN v22 · Dos correcciones al cuadre del 5/11
-- Ejecutar DESPUÉS de migracion_v21.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Los $50 que faltaban en Binance están guardados en Zelle: se aclara en la nota del ajuste.
--  2. Del conteo de 41.297 Bs se descuentan 10.000 del vuelto de Kyuran (conteo real: 31.297 Bs).
-- =====================================================================
do $$
begin
  if exists (select 1 from cargas_hechas where clave = 'v22_zelle_vuelto') then
    raise notice 'La v22 ya estaba aplicada. No se repite.'; return;
  end if;

  update movimientos
     set nota = 'Estos $50 no están en Binance: están guardados en Zelle'
   where concilia and cuenta = 'binance' and monto = -50 and fecha = '2026-11-05';

  insert into movimientos (fecha, cuenta, monto, nota, concilia)
  values ('2026-11-05', 'bs', -10000, 'Corrección del conteo: de los 41.297 Bs se descuentan 10.000 del vuelto de Kyuran (conteo real 31.297 Bs)', true);

  insert into cargas_hechas (clave) values ('v22_zelle_vuelto');
end $$;
