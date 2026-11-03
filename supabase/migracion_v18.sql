-- =====================================================================
-- MIGRACIÓN v18 · Gastos a cargo de ciertos socios, pagos/bonificaciones a socios y el almuerzo del 2/11
-- Ejecutar DESPUÉS de migracion_v17.sql. Se aplica UNA sola vez aunque la repitas.
--  1. gastos.socios: a quién se le descuenta el gasto (vacío = a todos los socios, como hasta ahora).
--  2. retiros_socios: bonificaciones, reparto de ganancia u otros pagos a un socio. Descuentan de la caja.
--  3. Gasto: almuerzo de Juan y George, 32.022 Bs a tasa BCV $ 891,10 = $35,94, mitad y mitad (no afecta a Rosanny).
--     Lo pagaron ellos de su bolsillo, así que no baja la caja.
-- =====================================================================
alter table gastos add column if not exists socios text[];

create table if not exists retiros_socios (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  socio text not null,
  tipo text not null default 'bonificacion' check (tipo in ('bonificacion','reparto','otro')),
  cuenta text not null check (cuenta in ('efectivo','binance','bs')),
  monto numeric not null check (monto > 0),          -- en $ (efectivo/Binance) o en Bs (cuenta bs)
  tasa numeric check (tasa > 0),                      -- solo Bs: tasa a la que se valora en dólares
  monto_usd numeric not null check (monto_usd > 0),   -- lo que equivale en dólares
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table retiros_socios enable row level security;
drop policy if exists solo_socios on retiros_socios;
create policy solo_socios on retiros_socios for all using (es_socio()) with check (es_socio());

-- La caja: lo que se le paga a un socio sale de la cuenta de la que se tomó
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
  union all select cuenta, -monto from retiros_socios
  union all select 'bs', -bs from conversiones
  union all select cuenta, divisa from conversiones
) x group by cuenta;

-- Almuerzo del 2/11
insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por, socios)
select '2026-11-02', 'otro', 'Almuerzo de Juan y George (32.022 Bs a tasa BCV $ 891,10)', round(32022 / 891.10, 2), null, null, 'Juan y George', array['Juan', 'George']
where not exists (select 1 from gastos where concepto like 'Almuerzo de Juan y George%');

insert into cargas_hechas (clave) values ('v18_socios_almuerzo') on conflict do nothing;
