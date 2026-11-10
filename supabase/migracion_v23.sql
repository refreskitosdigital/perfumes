-- =====================================================================
-- MIGRACIÓN v23 · Abono de $20 en efectivo del cliente Carpintero (5/11)
-- Ejecutar DESPUÉS de migracion_v22.sql. Se aplica UNA sola vez aunque la repitas.
-- Carpintero compró el Bharara Viking Kashmir ($45): abona $20 y le quedan $25.
-- =====================================================================
do $$
declare v_id bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'v23_carpintero_5nov') then
    raise notice 'La v23 ya estaba aplicada. No se repite.'; return;
  end if;
  select v.id into v_id from ventas_v v
   where norm_txt(v.cliente) = 'carpintero' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo del cliente Carpintero. No se aplicó nada.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-05', 'efectivo', 20);
  insert into cargas_hechas (clave) values ('v23_carpintero_5nov');
end $$;
