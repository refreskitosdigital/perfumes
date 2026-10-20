-- =====================================================================
-- CONTROL DE PERFUMES · Esquema de Supabase (v2)
-- Pegar completo en: Supabase > SQL Editor > New query > Run
-- Al final hay un bloque "SOCIOS" que se ejecuta aparte con los correos reales.
-- =====================================================================

-- ---------- Socios con acceso a la app ----------
create table if not exists socios (
  email text primary key,
  nombre text not null unique
);

create or replace function es_socio() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from socios where lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));
$$;

-- ---------- Configuración ----------
create table if not exists config (
  id int primary key default 1 check (id = 1),
  ganancia_objetivo numeric not null default 0.30,
  redondeo numeric not null default 0.5,
  umbral_mayor int not null default 6,
  base_ganancia text not null default 'costo' check (base_ganancia in ('costo','venta'))
);
insert into config (id) values (1) on conflict do nothing;

-- ---------- Tasas diarias ----------
create table if not exists tasas (
  fecha date primary key,
  bcv numeric not null check (bcv > 0),
  binance numeric not null check (binance > 0)
);

-- ---------- Perfumes (SKU automático) ----------
create sequence if not exists perfume_seq;
create table if not exists perfumes (
  id bigint generated always as identity primary key,
  sku text unique not null default ('PRF-' || lpad(nextval('perfume_seq')::text, 3, '0')),
  nombre text not null,
  precio_detal numeric check (precio_detal >= 0),
  precio_mayor numeric check (precio_mayor >= 0),
  creado timestamptz not null default now()
);
create unique index if not exists perfumes_nombre_uq on perfumes (lower(trim(nombre)));

-- ---------- Pedidos y quiénes participan en cada uno ----------
create table if not exists pedidos (
  codigo text primary key,
  fecha date not null default current_date,
  proveedor text,
  envio numeric not null default 0 check (envio >= 0)
);

-- Cada pedido tiene sus propios socios: aporte y % de la ganancia de ESE pedido.
create table if not exists pedido_socios (
  pedido_codigo text not null references pedidos(codigo) on update cascade on delete cascade,
  socio text not null,
  aporte numeric not null default 0,
  participacion numeric not null check (participacion >= 0 and participacion <= 1),
  primary key (pedido_codigo, socio)
);

create table if not exists compras (
  id bigint generated always as identity primary key,
  pedido_codigo text not null references pedidos(codigo) on update cascade on delete cascade,
  perfume_id bigint not null references perfumes(id),
  unidades int not null check (unidades > 0),
  costo_unitario numeric not null check (costo_unitario >= 0)
);

-- ---------- Ventas (cada venta sale de un pedido; sin pedido = venta anticipada) ----------
create table if not exists ventas (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  cliente text not null,
  vendedor text not null,
  perfume_id bigint not null references perfumes(id),
  pedido_codigo text references pedidos(codigo) on update cascade,
  unidades int not null default 1 check (unidades > 0),
  precio_unit numeric not null check (precio_unit >= 0),
  base text not null default 'divisa' check (base in ('divisa','bcv')), -- 'bcv': el precio está en BCV$ (se paga en Bs a tasa BCV)
  tasa_bcv numeric not null,
  tasa_binance numeric not null,
  vence date,                      -- fecha prometida de pago del saldo
  nota text
);

-- Cobros / abonos: una venta puede tener varios
create table if not exists cobros (
  id bigint generated always as identity primary key,
  venta_id bigint not null references ventas(id) on delete cascade,
  fecha date not null default current_date,
  cuenta text not null check (cuenta in ('binance','efectivo','bs')),
  monto numeric not null check (monto > 0),     -- en Bs si la cuenta es bs; en $ si no
  tasa_binance numeric                          -- solo Bs: tasa con la que se valora; vacío = la de la venta
);

-- ---------- Movimientos manuales de caja ----------
create table if not exists movimientos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  cuenta text not null check (cuenta in ('binance','efectivo','bs')),
  monto numeric not null,
  nota text
);

-- ---------- Préstamos ----------
create table if not exists prestamos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  descripcion text not null,
  prestamista text,
  monto numeric not null check (monto > 0),
  devuelto numeric not null default 0 check (devuelto >= 0)
);

-- ---------- Agenda de pedidos (no cuenta en inventario ni compras) ----------
create table if not exists agenda_pedidos (
  codigo text primary key,
  fecha_prevista date,
  proveedor text,
  envio numeric not null default 0,
  registrado boolean not null default false
);
create table if not exists agenda_socios (
  codigo text not null references agenda_pedidos(codigo) on update cascade on delete cascade,
  socio text not null,
  aporte numeric not null default 0,
  primary key (codigo, socio)
);
create table if not exists agenda_lineas (
  id bigint generated always as identity primary key,
  codigo text not null references agenda_pedidos(codigo) on update cascade on delete cascade,
  nombre text not null,
  unidades int not null check (unidades > 0),
  costo_unitario numeric not null check (costo_unitario >= 0),
  precio_detal numeric
);

-- =====================================================================
-- VISTAS
-- =====================================================================

-- Costo real por unidad = costo + envío repartido en partes iguales entre las unidades del pedido
create or replace view compras_v with (security_invoker = true) as
select c.id, c.pedido_codigo, p.fecha, p.proveedor, pf.sku, pf.nombre, c.perfume_id,
       c.unidades, c.costo_unitario,
       c.costo_unitario + case when t.unidades > 0 then p.envio / t.unidades else 0 end as costo_real,
       c.unidades * c.costo_unitario as mercancia
from compras c
join pedidos p on p.codigo = c.pedido_codigo
join perfumes pf on pf.id = c.perfume_id
join (select pedido_codigo, sum(unidades) as unidades from compras group by pedido_codigo) t
  on t.pedido_codigo = c.pedido_codigo;

create or replace view pedidos_v with (security_invoker = true) as
select p.*,
       coalesce(m.unidades, 0) as unidades,
       coalesce(m.mercancia, 0) as mercancia,
       coalesce(m.mercancia, 0) + p.envio as inversion,
       coalesce(s.aportes, 0) as aportes,
       coalesce(s.aportes, 0) - (coalesce(m.mercancia, 0) + p.envio) as diferencia,
       coalesce(s.socios, '') as socios
from pedidos p
left join (select pedido_codigo, sum(unidades) unidades, sum(unidades*costo_unitario) mercancia
           from compras group by pedido_codigo) m on m.pedido_codigo = p.codigo
left join (select pedido_codigo, sum(aporte) aportes,
                  string_agg(socio || ' ' || round(participacion*100)::text || '%', ' · ' order by socio) socios
           from pedido_socios group by pedido_codigo) s on s.pedido_codigo = p.codigo;

create or replace view costos_pedido_v with (security_invoker = true) as
select pedido_codigo, perfume_id, sum(unidades*costo_real)/sum(unidades) as costo_real
from compras_v group by pedido_codigo, perfume_id;

-- Valor real de la venta en $: si el precio es BCV$, equivale a precio × BCV / Binance
-- (la divisa se repone a Binance). Los Bs cobrados se valoran con la tasa Binance.
create or replace view ventas_v with (security_invoker = true) as
select x.*,
       x.valor_usd - x.cobrado_usd as pendiente_usd,
       x.costo_unit * x.unidades as costo_total,
       case when x.costo_unit is null then null else x.valor_usd - x.costo_unit * x.unidades end as ganancia
from (
  select v.*, pf.sku, pf.nombre,
         v.unidades * v.precio_unit as total_pactado,
         case when v.base = 'bcv' then v.unidades * v.precio_unit * v.tasa_bcv / v.tasa_binance
              else v.unidades * v.precio_unit end as valor_usd,
         coalesce((select sum(case when co.cuenta = 'bs' then co.monto / coalesce(co.tasa_binance, v.tasa_binance) else co.monto end)
                   from cobros co where co.venta_id = v.id), 0) as cobrado_usd,
         (select cp.costo_real from costos_pedido_v cp
           where cp.pedido_codigo = v.pedido_codigo and cp.perfume_id = v.perfume_id) as costo_unit
  from ventas v join perfumes pf on pf.id = v.perfume_id
) x;

-- Unidades que le quedan a cada pedido por perfume (para vender primero lo más antiguo)
create or replace view stock_pedido_v with (security_invoker = true) as
select c.pedido_codigo, c.fecha, c.perfume_id, c.nombre, c.sku,
       sum(c.unidades) as comprados,
       coalesce(max(s.vendidos), 0) as vendidos,
       sum(c.unidades) - coalesce(max(s.vendidos), 0) as restante
from compras_v c
left join (select pedido_codigo, perfume_id, sum(unidades) vendidos from ventas
           where pedido_codigo is not null group by pedido_codigo, perfume_id) s
  on s.pedido_codigo = c.pedido_codigo and s.perfume_id = c.perfume_id
group by c.pedido_codigo, c.fecha, c.perfume_id, c.nombre, c.sku;

create or replace view inventario_v with (security_invoker = true) as
select pf.id, pf.sku, pf.nombre, pf.precio_detal, pf.precio_mayor,
       coalesce(c.unid, 0) as comprados,
       coalesce(s.unid, 0) as vendidos,
       coalesce(c.unid, 0) - coalesce(s.unid, 0) as stock,
       coalesce(c.costo_prom, 0) as costo,
       round(case when coalesce(c.costo_prom,0) > 0 and pf.precio_detal is not null
             then (pf.precio_detal - c.costo_prom) / c.costo_prom end, 4) as margen_detal,
       round(case when coalesce(c.costo_prom,0) > 0 and coalesce(pf.precio_mayor, pf.precio_detal) is not null
             then (coalesce(pf.precio_mayor, pf.precio_detal) - c.costo_prom) / c.costo_prom end, 4) as margen_mayor,
       coalesce(s.ganancia, 0) as ganancia
from perfumes pf
left join (select perfume_id, sum(unidades) unid, sum(unidades*costo_real)/nullif(sum(unidades),0) costo_prom
           from compras_v group by perfume_id) c on c.perfume_id = pf.id
left join (select perfume_id, sum(unidades) unid, sum(ganancia) ganancia
           from ventas_v group by perfume_id) s on s.perfume_id = pf.id;

-- Resultado por pedido
create or replace view ganancia_pedido_v with (security_invoker = true) as
select p.codigo, p.fecha, p.inversion,
       coalesce(g.valor, 0) as ventas_usd, coalesce(g.cobrado, 0) as cobrado_usd,
       coalesce(g.pendiente, 0) as pendiente_usd, coalesce(g.costo, 0) as costo_vendido,
       coalesce(g.ganancia, 0) as ganancia
from pedidos_v p
left join (select pedido_codigo, sum(valor_usd) valor, sum(cobrado_usd) cobrado, sum(pendiente_usd) pendiente,
                  sum(costo_total) costo, sum(ganancia) ganancia
           from ventas_v where pedido_codigo is not null group by pedido_codigo) g
  on g.pedido_codigo = p.codigo;

-- Ganancia y aportes por socio: cada pedido reparte SOLO entre sus propios socios
create or replace view ganancia_socios_v with (security_invoker = true) as
select ps.socio,
       sum(ps.aporte) as aportes,
       sum(g.ganancia * ps.participacion) as ganancia
from pedido_socios ps
join ganancia_pedido_v g on g.codigo = ps.pedido_codigo
group by ps.socio;

-- Por cobrar
create or replace view por_cobrar_v with (security_invoker = true) as
select id, fecha, cliente, vendedor, nombre, sku, unidades, base, total_pactado, valor_usd, cobrado_usd, pendiente_usd, vence
from ventas_v where pendiente_usd > 0.01;

-- Saldos de caja por cuenta
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
) x group by cuenta;

-- =====================================================================
-- FUNCIONES
-- =====================================================================

-- Crear un pedido completo en un solo paso.
-- p_socios: [{"socio":"Juan","aporte":72.5}, ...]  (opcional "participacion": 0.5; si falta, es proporcional al aporte)
-- p_lineas: [{"nombre":"Fantasy","unidades":1,"costo_unitario":15,"precio_detal":25}, ...]
create or replace function crear_pedido(
  p_codigo text, p_fecha date, p_proveedor text, p_envio numeric, p_socios jsonb, p_lineas jsonb
) returns text
language plpgsql security invoker set search_path = public as $$
declare
  l jsonb; s jsonb;
  pid bigint; nom text;
  total numeric := 0; n int;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  if p_lineas is null or jsonb_array_length(p_lineas) = 0 then
    raise exception 'El pedido % no tiene perfumes', p_codigo;
  end if;
  if p_socios is null or jsonb_array_length(p_socios) = 0 then
    raise exception 'El pedido % necesita al menos un socio', p_codigo;
  end if;
  if exists (select 1 from pedidos where codigo = p_codigo) then
    raise exception 'El pedido % ya existe', p_codigo;
  end if;

  insert into pedidos (codigo, fecha, proveedor, envio)
  values (p_codigo, coalesce(p_fecha, current_date), p_proveedor, coalesce(p_envio,0));

  select coalesce(sum(coalesce((x ->> 'aporte')::numeric, 0)), 0), count(*) into total, n
  from jsonb_array_elements(p_socios) x;
  for s in select * from jsonb_array_elements(p_socios) loop
    insert into pedido_socios (pedido_codigo, socio, aporte, participacion)
    values (p_codigo, s ->> 'socio', coalesce((s ->> 'aporte')::numeric, 0),
            coalesce(nullif(s ->> 'participacion','')::numeric,
                     case when total > 0 then coalesce((s ->> 'aporte')::numeric, 0) / total else 1.0 / n end));
  end loop;
  if (select abs(sum(participacion) - 1) from pedido_socios where pedido_codigo = p_codigo) > 0.001 then
    raise exception 'Las participaciones del pedido % deben sumar 100 %%', p_codigo;
  end if;

  for l in select * from jsonb_array_elements(p_lineas) loop
    nom := trim(l ->> 'nombre');
    if nom is null or nom = '' then raise exception 'Hay una línea sin nombre de perfume'; end if;
    select id into pid from perfumes where lower(trim(nombre)) = lower(nom);
    if pid is null then
      insert into perfumes (nombre, precio_detal)
      values (nom, nullif(l ->> 'precio_detal','')::numeric) returning id into pid;
    elsif nullif(l ->> 'precio_detal','') is not null then
      update perfumes set precio_detal = coalesce(precio_detal, (l ->> 'precio_detal')::numeric) where id = pid;
    end if;
    insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
    values (p_codigo, pid, (l ->> 'unidades')::int, (l ->> 'costo_unitario')::numeric);
  end loop;
  return p_codigo;
end $$;

-- Registrar un pedido de la Agenda: lo pasa a Pedidos, Compras e Inventario en un solo paso
create or replace function registrar_pedido(p_codigo text) returns text
language plpgsql security invoker set search_path = public as $$
declare a agenda_pedidos%rowtype;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into a from agenda_pedidos where codigo = p_codigo for update;
  if not found then raise exception 'El pedido % no existe en la Agenda', p_codigo; end if;
  if a.registrado then raise exception 'El pedido % ya está registrado', p_codigo; end if;

  perform crear_pedido(
    a.codigo, current_date, a.proveedor, a.envio,
    (select coalesce(jsonb_agg(jsonb_build_object('socio', socio, 'aporte', aporte)), '[]'::jsonb)
       from agenda_socios where codigo = p_codigo),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', nombre, 'unidades', unidades,
        'costo_unitario', costo_unitario, 'precio_detal', precio_detal) order by id), '[]'::jsonb)
       from agenda_lineas where codigo = p_codigo));

  update agenda_pedidos set registrado = true where codigo = p_codigo;
  return p_codigo;
end $$;

-- =====================================================================
-- SEGURIDAD (RLS): solo los correos de la tabla socios pueden leer y escribir
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['config','tasas','perfumes','pedidos','pedido_socios','compras','ventas','cobros',
                           'movimientos','prestamos','agenda_pedidos','agenda_socios','agenda_lineas']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
  end loop;
end $$;
alter table socios enable row level security;
drop policy if exists solo_socios on socios;
drop policy if exists leer_socios on socios;
create policy leer_socios on socios for select using (es_socio());
