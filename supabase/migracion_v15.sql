-- =====================================================================
-- MIGRACIÓN v15 · Cobros del 1/11 y cuadre de la caja con tu conteo real
-- Ejecutar DESPUÉS de migracion_v14.sql. Se aplica UNA sola vez aunque la repitas.
--  1. Cobros: Juan Perez $20 (efectivo), Hijo del Carpintero $20 en Bs a 993, Almari $22,50 en Bs a 889,
--     Andreina (esposa de Ismael) $17 en Bs a 991.
--  2. Cuadre: deja la caja en tu conteo real (efectivo $67, Binance $55, Bs 0). Los Bs que sobran en el sistema
--     se registran como COMPRA DE DIVISA (Bs entregados = todo el saldo en Bs; divisa recibida = lo que faltaba
--     para llegar a tus $67 y $55). Esos montos son inferidos: si tienes los reales, bórralos en
--     Finanzas > Caja > Convertir bolívares en divisa y regístralos con tus cifras.
-- =====================================================================
do $$
declare
  v_id bigint; r record; bcv_ref numeric;
  s_ef numeric; s_bin numeric; s_bs numeric;
  d_ef numeric; d_bin numeric; pe numeric; pb numeric; tot numeric; bs_e numeric; bs_b numeric;
  t_ef constant numeric := 67; t_bin constant numeric := 55;
begin
  if exists (select 1 from cargas_hechas where clave = 'v15_cobros_cuadre') then
    raise notice 'La v15 ya estaba aplicada. No se repite.'; return;
  end if;

  -- ---------- 1. Cobros ----------
  for r in select * from (values
      ('juan perez%',          'efectivo', 20::numeric,    null::numeric),
      ('hijo del carpintero%', 'bs',       20 * 993,       993),
      ('almari%',              'bs',       22.5 * 889,     889),
      ('andreina%',            'bs',       17 * 991,       991)
    ) as t(cliente, cuenta, monto, tasa)
  loop
    select v.id into v_id from ventas_v v where lower(v.cliente) like r.cliente and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
    if v_id is null then raise exception 'No encontré una venta con saldo de "%".', replace(r.cliente, '%', ''); end if;
    insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-01', r.cuenta, r.monto, r.tasa);
  end loop;

  -- ---------- 2. Cuadre con el conteo real ----------
  select coalesce(max(saldo) filter (where cuenta = 'efectivo'), 0), coalesce(max(saldo) filter (where cuenta = 'binance'), 0),
         coalesce(max(saldo) filter (where cuenta = 'bs'), 0)
    into s_ef, s_bin, s_bs from caja_v;
  select bcv into bcv_ref from tasas where bcv > 0 order by fecha desc limit 1;
  d_ef := t_ef - s_ef; d_bin := t_bin - s_bin;
  pe := greatest(d_ef, 0); pb := greatest(d_bin, 0); tot := pe + pb;

  if s_bs > 0.005 and tot > 0.005 and coalesce(bcv_ref, 0) > 0 then
    bs_e := round(s_bs * pe / tot, 2); bs_b := round(s_bs - bs_e, 2);
    if pe > 0.005 then
      insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_e, round(pe, 2), 'efectivo', bcv_ref, 'Inferida al cuadrar la caja: reemplaza con tus cifras reales');
    end if;
    if pb > 0.005 then
      insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_b, round(pb, 2), 'binance', bcv_ref, 'Inferida al cuadrar la caja: reemplaza con tus cifras reales');
    end if;
  elsif abs(s_bs) > 0.005 then
    insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'bs', -s_bs, 'Ajuste al conteo real de la caja');
  end if;

  -- Lo que sobre o falte en divisa tras la conversión se ajusta como movimiento
  if d_ef < -0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', round(d_ef, 2), 'Ajuste al conteo real de la caja'); end if;
  if d_bin < -0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'binance', round(d_bin, 2), 'Ajuste al conteo real de la caja'); end if;
  if not (s_bs > 0.005 and tot > 0.005 and coalesce(bcv_ref, 0) > 0) then
    if d_ef > 0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', round(d_ef, 2), 'Ajuste al conteo real de la caja'); end if;
    if d_bin > 0.005 then insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'binance', round(d_bin, 2), 'Ajuste al conteo real de la caja'); end if;
  end if;

  insert into cargas_hechas (clave) values ('v15_cobros_cuadre');
  raise notice 'Antes del cuadre el sistema tenía: efectivo %, Binance %, Bs %.', round(s_ef, 2), round(s_bin, 2), round(s_bs, 2);
end $$;
