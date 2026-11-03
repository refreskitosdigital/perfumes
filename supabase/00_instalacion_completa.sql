-- =====================================================================
-- INSTALACIÓN COMPLETA · de cero hasta la migración 14 (todo en un solo archivo)
-- Úsalo en un proyecto de Supabase NUEVO y vacío. Si ya tienes la base funcionando,
-- NO lo uses: ejecuta solo lo que te falta (por ejemplo entrega_v11_a_v17.sql).
--
-- Orden que sigue este archivo:
--   schema → seed pedidos 1 y 2 → seed pedido 3 → v3 → v4 → v5 → v6 → v7
--   → TASAS DE HOY (las 3 cifras que editas abajo) → v8 → v9 → v10 → v11 → v12 → cobros 30/10 → v13 → v14 → v16 → v17
--
-- IMPORTANTE: busca el bloque "EDITA ESTAS 3 CIFRAS" (a mitad del archivo) y escribe las
-- tasas de hoy. Si las dejas vacías, el archivo se detiene con un aviso.
-- Después crea tus usuarios en Authentication (ver README, paso 3 y 4).
-- Se ejecuta de una vez (Run). Si algo falla, el mensaje dice cuál perfume o dato falta.
-- =====================================================================

-- >>>>>>>>>> schema.sql <<<<<<<<<<
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

-- >>>>>>>>>> seed_pedidos_1_2.sql <<<<<<<<<<
-- =====================================================================
-- DATOS REALES: Pedidos 1 y 2 (ejecutar DESPUÉS de schema.sql)
-- Ambos pedidos: Juan 50 % · George 50 %. Rosanny entra desde el pedido 3.
-- Fechas de ventas: se usó la fecha de cada compra (07/10 y 16/10) porque no se
-- indicó la fecha exacta; se pueden corregir en la app.
-- =====================================================================

insert into tasas (fecha, bcv, binance) values
  ('2026-10-07', 876.79, 1015),
  ('2026-10-16', 881, 1015)       -- Binance del 16/10 asumido (1015): corregir en Tasas si fue otro
on conflict (fecha) do nothing;

-- ---------- Perfumes (nombre, precio de venta al detal) ----------
insert into perfumes (nombre, precio_detal) values
  ('La Bomba Carolina Herrera', 40), ('Meow Katy Perry', 25), ('Valentino Donna Intense', 38),
  ('Invictus Parfum Paco Rabanne', 40), ('Set de regalo Odyssey Collection', 45), ('Fantasy', 25),
  ('9 PM Night Out', 35),
  ('Paris Hilton Can Can', 35), ('Afnan 9am Femme', 25), ('Carolina Herrera Bad Boy', 30),
  ('Armaf Beach Party', null), ('Carolina Herrera 212 VIP Fem', 30), ('Orientica Amber Rouge', 35),
  ('Lattafa Khamrah Karaz Unisex Lujo Premium', 40), ('One Million Paco Rabanne', null),
  ('Mont Blanc Starwalker Men', 35), ('Lacoste White Men', 30), ('Armaf Odyssey Mega Men', 30),
  ('Bharara Rose Fem Lujo Premium', 30), ('Victoria Secret Splash 250ml (variados)', 10),
  ('Carolina Herrera Good Girl Fem', 35), ('Giorgio Armani Acqua di Gio Men', 25)
on conflict do nothing;

-- ---------- Pedido 1 · 07/10 · $125 mercancía + $20 envío ----------
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-001', '2026-10-07', null, 20)
on conflict do nothing;
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-001', 'Juan', 72.5, 0.5), ('P-001', 'George', 72.5, 0.5) on conflict do nothing;

-- ---------- Pedido 2 · 16/10 · comprado en Caracas, sin envío ----------
-- Las 8 fragancias de splash se cargan como un solo producto: 16 unidades a $3 (factura: $6 por par)
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-002', '2026-10-16', 'Proveedor en Caracas', 0)
on conflict do nothing;
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-002', 'Juan', 127, 0.5), ('P-002', 'George', 127, 0.5) on conflict do nothing;

insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
select x.pedido, pf.id, x.unid, x.costo
from (values
  ('P-001','La Bomba Carolina Herrera',1,22), ('P-001','Meow Katy Perry',1,15),
  ('P-001','Valentino Donna Intense',1,15), ('P-001','Invictus Parfum Paco Rabanne',1,17),
  ('P-001','Set de regalo Odyssey Collection',1,23), ('P-001','Fantasy',1,15), ('P-001','9 PM Night Out',1,18),
  ('P-002','Paris Hilton Can Can',1,12), ('P-002','Afnan 9am Femme',1,13), ('P-002','Carolina Herrera Bad Boy',1,13),
  ('P-002','Armaf Beach Party',1,14), ('P-002','Carolina Herrera 212 VIP Fem',1,13), ('P-002','Orientica Amber Rouge',1,14),
  ('P-002','Lattafa Khamrah Karaz Unisex Lujo Premium',1,18), ('P-002','Invictus Parfum Paco Rabanne',1,13),
  ('P-002','One Million Paco Rabanne',1,13), ('P-002','Mont Blanc Starwalker Men',1,13), ('P-002','Lacoste White Men',1,12),
  ('P-002','Armaf Odyssey Mega Men',1,15), ('P-002','Bharara Rose Fem Lujo Premium',1,18),
  ('P-002','Victoria Secret Splash 250ml (variados)',16,3),
  ('P-002','Carolina Herrera Good Girl Fem',1,13), ('P-002','Giorgio Armani Acqua di Gio Men',1,12)
) as x(pedido, nombre, unid, costo)
join perfumes pf on lower(pf.nombre) = lower(x.nombre)
where not exists (select 1 from compras);

-- ---------- Ventas ----------
create temp table _v (
  fecha date, cliente text, vendedor text, nombre text, pedido text, unid int, precio numeric,
  base text, bcv numeric, bin numeric, vence date, nota text
);
insert into _v values
 -- Pedido 1
 ('2026-10-07','Maria Fernanda','Juan','La Bomba Carolina Herrera','P-001',1,40,'divisa',876.79,1015,'2026-10-30',null),
 ('2026-10-07','Mildred Ramos','Juan','Meow Katy Perry','P-001',1,22.5,'divisa',876.79,1015,null,'Combo Meow + Fantasy $45'),
 ('2026-10-07','Mildred Ramos','Juan','Fantasy','P-001',1,22.5,'divisa',876.79,1015,null,'Combo Meow + Fantasy $45'),
 ('2026-10-07','Neysimar','Juan','Valentino Donna Intense','P-001',1,38,'bcv',876.79,1015,'2026-10-30','Pagará en Bs'),
 ('2026-10-07','Eduin Torres','Juan','9 PM Night Out','P-001',1,35,'divisa',876.79,1015,'2026-10-30',null),
 ('2026-10-07','Ender Barbero','George','Set de regalo Odyssey Collection','P-001',1,45,'divisa',876.79,1015,null,null),
 ('2026-10-07','Ender Barbero','George','Invictus Parfum Paco Rabanne','P-001',1,40,'divisa',876.79,1015,null,null),
 -- Pedido 2
 ('2026-10-16','Albany Rebolledo','Juan','Paris Hilton Can Can','P-002',1,35,'bcv',881,1015,'2026-10-30','A tasa BCV'),
 ('2026-10-16','Luisa Teran','Juan','Afnan 9am Femme','P-002',1,25,'divisa',881,1015,'2026-10-30','Con 2 splash: total $40'),
 ('2026-10-16','Luisa Teran','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30','Con Afnan: total $40'),
 ('2026-10-16','Carlos Zuniga','Juan','Carolina Herrera Bad Boy','P-002',1,30,'divisa',881,1015,null,null),
 ('2026-10-16','Juan Montilva','Juan','Armaf Beach Party','P-002',1,20,'divisa',881,1015,null,null),
 ('2026-10-16','Rosalia Torres','Juan','Carolina Herrera 212 VIP Fem','P-002',1,30,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Maria Fernanda','Juan','Orientica Amber Rouge','P-002',1,35,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jesus Teran','Juan','Lattafa Khamrah Karaz Unisex Lujo Premium','P-002',1,40,'divisa',881,1015,'2026-10-30','Pagó $20, debe $20'),
 ('2026-10-16','George','George','Invictus Parfum Paco Rabanne','P-002',1,40,'divisa',881,1015,null,null),
 ('2026-10-16','Wuile Kyomu','Juan','Mont Blanc Starwalker Men','P-002',1,35,'divisa',881,1015,'2026-10-30','Pagó $20, debe $15'),
 ('2026-10-16','Kyuran','Juan','Lacoste White Men','P-002',1,30,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jean Mary de la Hoz','George','Armaf Odyssey Mega Men','P-002',1,30,'divisa',881,1015,'2026-10-30','Pagará $60 por Binance por ambos perfumes'),
 ('2026-10-16','Jean Mary de la Hoz','George','Bharara Rose Fem Lujo Premium','P-002',1,30,'divisa',881,1015,'2026-10-30','Pagará $60 por Binance por ambos perfumes'),
 ('2026-10-16','Doris Teran','Juan','Carolina Herrera Good Girl Fem','P-002',1,35,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Jose Montilva','Juan','Giorgio Armani Acqua di Gio Men','P-002',1,25,'divisa',881,1015,'2026-10-30',null),
 -- Splash
 ('2026-10-16','Gina Pena','Juan','Victoria Secret Splash 250ml (variados)','P-002',4,9,'bcv',881,1015,'2026-10-30','Pagó $18 en Bs a 881, debe $18'),
 ('2026-10-16','Anny Guitian','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Rosanny Cequea','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'divisa',881,1015,'2026-10-30','Socia a partir del pedido 3'),
 ('2026-10-16','Fabian Gago','Juan','Victoria Secret Splash 250ml (variados)','P-002',2,7.5,'bcv',881,1015,'2026-10-30','Pagó $7,50 en Bs a 881, debe $7,50'),
 ('2026-10-16','Lori Teran','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,985,null,'Pagó en Bs a tasa 985'),
 ('2026-10-16','Maria Fernanda','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Wuile Kyomu','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,7,'divisa',881,1015,'2026-10-30',null),
 ('2026-10-16','Kyuran','Juan','Victoria Secret Splash 250ml (variados)','P-002',1,10,'divisa',881,1015,'2026-10-30','Con Lacoste'),
 -- Venta anticipada: aún no se compra el perfume (entra en el pedido 3)
 ('2026-10-16','Rosangela Cequea','Juan','Valentino Donna Intense',null,1,38,'bcv',881,1015,null,'Prepagó $19 a BCV. Hay que comprar el perfume (pedido 3) y asignarle el pedido');

insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
select v.fecha, v.cliente, v.vendedor, pf.id, v.pedido, v.unid, v.precio, v.base, v.bcv, v.bin, v.vence, v.nota
from _v v join perfumes pf on lower(pf.nombre) = lower(v.nombre)
where not exists (select 1 from ventas);

-- ---------- Cobros ya recibidos ----------
create temp table _c (cliente text, nombre text, cuenta text, monto numeric);
insert into _c values
 ('Mildred Ramos','Meow Katy Perry','binance',22.5), ('Mildred Ramos','Fantasy','binance',22.5),
 ('Eduin Torres','9 PM Night Out','efectivo',20),
 ('Ender Barbero','Set de regalo Odyssey Collection','efectivo',45),
 ('Ender Barbero','Invictus Parfum Paco Rabanne','efectivo',40),
 ('Carlos Zuniga','Carolina Herrera Bad Boy','efectivo',30),
 ('Juan Montilva','Armaf Beach Party','efectivo',20),
 ('Jesus Teran','Lattafa Khamrah Karaz Unisex Lujo Premium','efectivo',20),
 ('George','Invictus Parfum Paco Rabanne','efectivo',40),
 ('Wuile Kyomu','Mont Blanc Starwalker Men','efectivo',20),
 ('Gina Pena','Victoria Secret Splash 250ml (variados)','bs',15858),      -- $18 × 881
 ('Fabian Gago','Victoria Secret Splash 250ml (variados)','bs',6607.5),   -- $7,50 × 881
 ('Lori Teran','Victoria Secret Splash 250ml (variados)','bs',9850),      -- $10 × 985
 ('Rosangela Cequea','Valentino Donna Intense','bs',16739);              -- $19 × 881

insert into cobros (venta_id, fecha, cuenta, monto)
select v.id, v.fecha, c.cuenta, c.monto
from _c c
join perfumes pf on lower(pf.nombre) = lower(c.nombre)
join ventas v on v.cliente = c.cliente and v.perfume_id = pf.id
where not exists (select 1 from cobros);

-- ---------- Préstamo para pagar el pedido 2 ----------
insert into prestamos (fecha, descripcion, prestamista, monto)
select '2026-10-16', 'Préstamo para pagar el pedido P-002 (se devuelve con las ventas)', 'REFRESKITO Digital', 254
where not exists (select 1 from prestamos);

-- =====================================================================
-- SOCIOS (ejecutar aparte, con los correos reales)
-- =====================================================================
-- insert into socios (email, nombre) values
--   ('correo.de.juan@gmail.com', 'Juan'),
--   ('correo.de.george@gmail.com', 'George'),
--   ('correo.de.rosanny@gmail.com', 'Rosanny');   -- puede agregarse al crear el pedido 3

-- >>>>>>>>>> seed_pedido_3.sql <<<<<<<<<<
-- =====================================================================
-- Pedido 3 (ejecutar DESPUÉS de schema.sql y seed_pedidos_1_2.sql)
-- 3 socios en partes iguales (Juan, George, Rosanny): 1/3 de la ganancia cada uno.
-- Inversión: $514 = Caja acumulada $328,33 (Juan+George) + Rosanny $100 efectivo
--            + préstamo REFRESKITO Digital $85,67 ($71 completan el tercio de Rosanny + $14,67 de diferencia)
-- Los $71 prestados a Rosanny son deuda DEL NEGOCIO (se devuelven entre los 3).
-- Fecha del pedido: 19/10/2026 (ajustable en la app).
-- =====================================================================

-- ---------- Socios (correos de acceso) ----------
insert into socios (email, nombre) values
  ('juanjmontilvat@gmail.com', 'Juan'),      -- CONFIRMAR: llegó escrito "juanjmontilvatgmail.com"
  ('georfredt2.0@gmail.com', 'George'),
  ('rosandrea010803@gmail.com', 'Rosanny')
on conflict (email) do nothing;

-- ---------- Perfumes nuevos (precio_detal vacío = la app sugiere costo + 30 %) ----------
insert into perfumes (nombre) values
  ('Ariana Grande Cloud'), ('Ariana Grande Thank U Next'), ('Bestia Negra'),
  ('Carolina Herrera 212 VIP'), ('Carolina Herrera 212 VIP Black'), ('Carolina Herrera La Vie Est Belle'),
  ('Lattafa Art of Universe'), ('Lattafa Asad Men'), ('Lattafa Mayar Lujo Premium'),
  ('Lattafa Yara Candy Fem'), ('Lattafa Yara Fem'), ('Paco Rabanne Invictus Intense'),
  ('Santal 33'), ('Valentino Born in Roma Intense'), ('Armaf Odyssey Mandarin Sky Elixir'),
  ('Ariana Grande Mod Vainilla'), ('Ariana Grande Mod Blush'), ('Victorinox'),
  ('Perry Ellis Coral'), ('Perry Ellis 360'), ('Armaf Odyssey Tyrant Men'), ('Moschino Toy Boy')
on conflict do nothing;

-- ---------- Pedido ----------
insert into pedidos (codigo, fecha, proveedor, envio) values ('P-003', '2026-10-19', null, 0)
on conflict do nothing;

-- Aportes (1/3 cada uno). Juan y George: caja + parte del préstamo; Rosanny: $100 efectivo + $71 préstamo
insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
  ('P-003', 'Juan',    171.33, 1.0/3),
  ('P-003', 'George',  171.33, 1.0/3),
  ('P-003', 'Rosanny', 171.34, 1.0/3)
on conflict do nothing;

-- ---------- Compras (51 unidades · $514) ----------
insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
select 'P-003', pf.id, x.unid, x.costo
from (values
  ('Ariana Grande Cloud',2,12), ('Ariana Grande Thank U Next',2,12), ('Bestia Negra',2,12),
  ('Bharara Rose Fem Lujo Premium',1,16), ('Carolina Herrera 212 VIP',1,11), ('Carolina Herrera 212 VIP Black',1,11),
  ('Carolina Herrera Good Girl Fem',2,11), ('Carolina Herrera La Vie Est Belle',1,10), ('Lattafa Art of Universe',1,19),
  ('Lattafa Asad Men',3,12), ('Lattafa Mayar Lujo Premium',1,16), ('Lattafa Yara Candy Fem',3,12),
  ('Lattafa Yara Fem',3,12), ('Invictus Parfum Paco Rabanne',1,11), ('Paco Rabanne Invictus Intense',1,10),
  ('One Million Paco Rabanne',1,11), ('Santal 33',2,12), ('Fantasy',2,10),
  ('Valentino Born in Roma Intense',1,12), ('Armaf Odyssey Mandarin Sky Elixir',1,13),
  ('Ariana Grande Mod Vainilla',1,11), ('Ariana Grande Mod Blush',1,11), ('Victorinox',2,11),
  ('9 PM Night Out',1,13), ('Perry Ellis Coral',1,10), ('Perry Ellis 360',1,10),
  ('Armaf Odyssey Tyrant Men',1,13), ('Moschino Toy Boy',1,13),
  ('Victoria Secret Splash 250ml (variados)',10,2.5)
) as x(nombre, unid, costo)
join perfumes pf on lower(pf.nombre) = lower(x.nombre)
where not exists (select 1 from compras where pedido_codigo = 'P-003');

-- ---------- Financiamiento ----------
-- La caja acumulada ($328,33) se usa para pagar el pedido: se descuenta de cada cuenta.
insert into movimientos (fecha, cuenta, monto, nota)
select '2026-10-19', c, m, 'Pago pedido P-003 con la caja acumulada'
from (values ('binance', -45::numeric), ('efectivo', -235), ('bs', -49054.5)) v(c, m)
where not exists (select 1 from movimientos where nota = 'Pago pedido P-003 con la caja acumulada');

insert into prestamos (fecha, descripcion, prestamista, monto)
select '2026-10-19', d, 'REFRESKITO Digital', m
from (values
  ('Préstamo a Rosanny para completar su tercio del pedido P-003 (deuda del negocio)', 71::numeric),
  ('Préstamo para completar el pago del pedido P-003', 14.67)
) v(d, m)
where not exists (select 1 from prestamos where descripcion like '%P-003%');
-- Deuda total con REFRESKITO Digital: 254 + 71 + 14,67 = 339,67

-- >>>>>>>>>> migracion_v3.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V3 · Clientes, Pagos y "Realizar pedido" con financiamiento
-- Se ejecuta UNA VEZ en el SQL Editor, DESPUÉS de schema.sql y de los seeds.
-- Es segura de repetir: no borra datos ni duplica lo que ya existe.
-- =====================================================================

-- ---------- CLIENTES ----------
create table if not exists clientes (
  id bigint generated always as identity primary key,
  nombre text not null,
  telefono text,
  notas text,
  creado date not null default current_date
);
create unique index if not exists clientes_nombre_uq on clientes (lower(trim(nombre)));

-- Cada venta nueva crea al cliente si todavía no existe
create or replace function cliente_auto() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  insert into clientes (nombre) values (trim(new.cliente)) on conflict do nothing;
  return new;
end $$;
drop trigger if exists ventas_cliente_auto on ventas;
create trigger ventas_cliente_auto before insert on ventas
  for each row execute function cliente_auto();

-- Clientes de las ventas que ya existen
insert into clientes (nombre)
select distinct on (lower(trim(cliente))) trim(cliente) from ventas
where trim(cliente) <> ''
on conflict do nothing;

-- ---------- PAGOS (historial transparente para todos los socios) ----------
-- tipo: 'proveedor' (compra de un pedido), 'deuda' (devolución de un préstamo), 'otro'
-- fuente: de dónde salió el dinero: 'caja', 'socio' (puso efectivo un socio), 'prestamo'
create table if not exists pagos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  tipo text not null check (tipo in ('proveedor','deuda','otro')),
  concepto text not null,
  pedido_codigo text references pedidos(codigo) on update cascade on delete set null,
  prestamo_id bigint references prestamos(id) on delete set null,
  monto numeric not null check (monto > 0),                 -- siempre en $
  cuenta text check (cuenta in ('binance','efectivo','bs')),
  estado text not null default 'pendiente' check (estado in ('pendiente','pagado')),
  fecha_pago date,
  fuente text check (fuente in ('caja','socio','prestamo')),
  pagado_por text,
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);

-- ---------- Funciones ----------
-- Registrar un pedido de la Agenda (ahora con fecha). Reemplaza a la versión anterior.
drop function if exists registrar_pedido(text);
create or replace function registrar_pedido(p_codigo text, p_fecha date default null) returns text
language plpgsql security invoker set search_path = public as $$
declare a agenda_pedidos%rowtype;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into a from agenda_pedidos where codigo = p_codigo for update;
  if not found then raise exception 'El pedido % no existe en la Agenda', p_codigo; end if;
  if a.registrado then raise exception 'El pedido % ya está registrado', p_codigo; end if;

  perform crear_pedido(
    a.codigo, coalesce(p_fecha, current_date), a.proveedor, a.envio,
    (select coalesce(jsonb_agg(jsonb_build_object('socio', socio, 'aporte', aporte)), '[]'::jsonb)
       from agenda_socios where codigo = p_codigo),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'nombre', nombre, 'unidades', unidades,
        'costo_unitario', costo_unitario, 'precio_detal', precio_detal) order by id), '[]'::jsonb)
       from agenda_lineas where codigo = p_codigo));

  update agenda_pedidos set registrado = true where codigo = p_codigo;
  return p_codigo;
end $$;

-- REALIZAR PEDIDO: pasa el pedido de la Agenda a Compras/Inventario y registra de dónde sale el dinero.
--   p_caja:   [{"cuenta":"binance","monto":45,"usd":45}, ...]  (monto en la moneda de la cuenta, usd = su valor en $)
--   p_socios: [{"socio":"Rosanny","monto":100}, ...]           (efectivo que pone un socio directamente)
--   p_prestamo: lo que presta p_prestamista para completar (queda como deuda)
--   p_pagar_despues: true = se registra el pedido pero el pago al proveedor queda PENDIENTE
create or replace function realizar_pedido(
  p_codigo text, p_fecha date, p_caja jsonb, p_socios jsonb,
  p_prestamo numeric, p_prestamista text, p_pagar_despues boolean default false
) returns text
language plpgsql security invoker set search_path = public as $$
declare
  a agenda_pedidos%rowtype;
  total numeric; x jsonb; f date := coalesce(p_fecha, current_date);
  cta text; m numeric; mu numeric; saldo numeric;
  suma numeric := 0; pr_id bigint;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into a from agenda_pedidos where codigo = p_codigo;
  if not found then raise exception 'El pedido % no existe en la Agenda', p_codigo; end if;
  total := coalesce((select sum(unidades * costo_unitario) from agenda_lineas where codigo = p_codigo), 0) + a.envio;
  if total <= 0 then raise exception 'El pedido % no tiene monto', p_codigo; end if;

  perform registrar_pedido(p_codigo, f);

  if p_pagar_despues then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado)
    values (f, 'proveedor', 'Pago al proveedor · pedido ' || p_codigo, p_codigo, total, 'pendiente');
    return p_codigo;
  end if;

  for x in select * from jsonb_array_elements(coalesce(p_caja, '[]'::jsonb)) loop
    cta := x ->> 'cuenta'; m := coalesce((x ->> 'monto')::numeric, 0); mu := coalesce((x ->> 'usd')::numeric, 0);
    continue when m <= 0;
    select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = cta;
    if m > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', cta, saldo; end if;
    insert into movimientos (fecha, cuenta, monto, nota) values (f, cta, -m, 'Pago del pedido ' || p_codigo || ' con la caja');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, cuenta, estado, fecha_pago, fuente)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · desde la caja (' || cta || ')', p_codigo, mu, cta, 'pagado', f, 'caja');
    suma := suma + mu;
  end loop;

  for x in select * from jsonb_array_elements(coalesce(p_socios, '[]'::jsonb)) loop
    m := coalesce((x ->> 'monto')::numeric, 0);
    continue when m <= 0;
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · efectivo de ' || (x ->> 'socio'), p_codigo, m, 'pagado', f, 'socio', x ->> 'socio');
    suma := suma + m;
  end loop;

  if coalesce(p_prestamo, 0) > 0 then
    insert into prestamos (fecha, descripcion, prestamista, monto)
    values (f, 'Préstamo para pagar el pedido ' || p_codigo, nullif(trim(p_prestamista), ''), p_prestamo)
    returning id into pr_id;
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    values (f, 'proveedor', 'Pedido ' || p_codigo || ' · con préstamo', p_codigo, pr_id, p_prestamo, 'pagado', f, 'prestamo', nullif(trim(p_prestamista), ''));
    suma := suma + p_prestamo;
  end if;

  if abs(suma - total) > 0.011 then
    raise exception 'Lo pagado (%) no coincide con el total del pedido (%)', round(suma, 2), round(total, 2);
  end if;
  return p_codigo;
end $$;

-- Pagar un pago pendiente (de proveedor u otro) desde una cuenta de la caja o con dinero de un socio
create or replace function pagar_pendiente(
  p_id bigint, p_cuenta text, p_monto_cuenta numeric, p_pagado_por text, p_fecha date
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare pg pagos%rowtype; saldo numeric; f date := coalesce(p_fecha, current_date);
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into pg from pagos where id = p_id for update;
  if not found then raise exception 'El pago no existe'; end if;
  if pg.estado = 'pagado' then raise exception 'Ese pago ya está registrado como pagado'; end if;
  if p_cuenta in ('binance','efectivo','bs') then
    select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = p_cuenta;
    if coalesce(p_monto_cuenta, 0) > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', p_cuenta, saldo; end if;
    insert into movimientos (fecha, cuenta, monto, nota) values (f, p_cuenta, -p_monto_cuenta, 'Pago: ' || pg.concepto);
    update pagos set estado = 'pagado', fecha_pago = f, cuenta = p_cuenta, fuente = 'caja' where id = p_id;
  else
    update pagos set estado = 'pagado', fecha_pago = f, fuente = 'socio', pagado_por = p_pagado_por where id = p_id;
  end if;
  return p_id;
end $$;

-- Devolver (parte de) un préstamo: queda en el historial de pagos y baja la deuda
create or replace function pagar_deuda(
  p_prestamo bigint, p_monto_usd numeric, p_cuenta text, p_monto_cuenta numeric, p_fecha date
) returns bigint
language plpgsql security invoker set search_path = public as $$
declare pr prestamos%rowtype; saldo numeric; f date := coalesce(p_fecha, current_date); nuevo bigint;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into pr from prestamos where id = p_prestamo for update;
  if not found then raise exception 'El préstamo no existe'; end if;
  if p_monto_usd <= 0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_monto_usd > pr.monto - pr.devuelto + 0.011 then raise exception 'Es más de lo que se debe (%)', round(pr.monto - pr.devuelto, 2); end if;
  select coalesce(sum(c.saldo), 0) into saldo from caja_v c where c.cuenta = p_cuenta;
  if coalesce(p_monto_cuenta, 0) > saldo + 0.001 then raise exception 'No hay suficiente dinero en la cuenta % (hay %)', p_cuenta, saldo; end if;
  insert into movimientos (fecha, cuenta, monto, nota)
  values (f, p_cuenta, -p_monto_cuenta, 'Devolución de préstamo a ' || coalesce(pr.prestamista, 'prestamista') || ': ' || pr.descripcion);
  update prestamos set devuelto = devuelto + p_monto_usd where id = p_prestamo;
  insert into pagos (fecha, tipo, concepto, prestamo_id, monto, cuenta, estado, fecha_pago, fuente, pagado_por)
  values (f, 'deuda', 'Pago de deuda a ' || coalesce(pr.prestamista, 'prestamista') || ' · ' || pr.descripcion,
          p_prestamo, p_monto_usd, p_cuenta, 'pagado', f, 'caja', null)
  returning id into nuevo;
  return nuevo;
end $$;

-- ---------- Historial de pagos de los pedidos ya cargados (solo si Pagos está vacío) ----------
do $$
begin
  if exists (select 1 from pagos) then return; end if;

  if exists (select 1 from pedidos where codigo = 'P-001') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-07', 'proveedor', 'Pedido P-001 · efectivo de ' || socio, 'P-001', aporte, 'pagado', '2026-10-07', 'socio', socio
    from pedido_socios where pedido_codigo = 'P-001' order by socio;
  end if;

  if exists (select 1 from pedidos where codigo = 'P-002') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-16', 'proveedor', 'Pedido P-002 · con préstamo', 'P-002', pr.id, 254, 'pagado', '2026-10-16', 'prestamo', pr.prestamista
    from (select id, prestamista from prestamos where descripcion like '%P-002%' order by id limit 1) pr;
  end if;

  if exists (select 1 from pedidos where codigo = 'P-003') then
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, cuenta, estado, fecha_pago, fuente) values
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (binance)', 'P-003', 45, 'binance', 'pagado', '2026-10-19', 'caja'),
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (efectivo)', 'P-003', 235, 'efectivo', 'pagado', '2026-10-19', 'caja'),
      ('2026-10-19', 'proveedor', 'Pedido P-003 · desde la caja (bs)', 'P-003', 48.33, 'bs', 'pagado', '2026-10-19', 'caja');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, monto, estado, fecha_pago, fuente, pagado_por) values
      ('2026-10-19', 'proveedor', 'Pedido P-003 · efectivo de Rosanny', 'P-003', 100, 'pagado', '2026-10-19', 'socio', 'Rosanny');
    insert into pagos (fecha, tipo, concepto, pedido_codigo, prestamo_id, monto, estado, fecha_pago, fuente, pagado_por)
    select '2026-10-19', 'proveedor', 'Pedido P-003 · con préstamo (' ||
           case when descripcion like '%Rosanny%' then 'tercio de Rosanny' else 'diferencia' end || ')',
           'P-003', id, monto, 'pagado', '2026-10-19', 'prestamo', prestamista
    from prestamos where descripcion like '%P-003%' order by id;
  end if;
end $$;

-- ---------- Seguridad: solo los socios ven y escriben ----------
do $$
declare t text;
begin
  foreach t in array array['clientes','pagos'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
  end loop;
end $$;

-- >>>>>>>>>> migracion_v4.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V4 · Tienda online (pedidos web, perfumes agotados "Agendar pedido",
-- ajustes de la tienda y fotos). Se ejecuta UNA VEZ en el SQL Editor,
-- después de migracion_v3.sql. Es segura de repetir.
-- =====================================================================

-- ---------- Perfumes: foto y visibilidad en la tienda ----------
alter table perfumes add column if not exists foto_url text;
alter table perfumes add column if not exists visible_tienda boolean not null default true;

-- ---------- Ajustes de la tienda (los edita un socio desde la app) ----------
create table if not exists tienda_config (
  id int primary key default 1 check (id = 1),
  nombre text not null default 'Perfumes',
  whatsapp text,                                   -- número que recibe los pedidos, con código de país (ej. 584141234567)
  umbral_mayor int not null default 12,            -- perfumes en el carrito para el precio al mayor
  mensaje text,                                    -- frase corta bajo el título
  metodos jsonb not null default '[]'::jsonb       -- [{"titulo":"Pago móvil","detalle":"..."}]
);
insert into tienda_config (id, mensaje, metodos) values (
  1, 'Perfumes árabes y de diseñador, listos para entrega.',
  '[{"titulo":"Pago móvil / transferencia en Bs","detalle":"Te enviamos los datos por WhatsApp al confirmar."},
    {"titulo":"Efectivo en dólares","detalle":"Al momento de la entrega."},
    {"titulo":"Binance (USDT)","detalle":"Te enviamos el ID por WhatsApp al confirmar."}]'::jsonb
) on conflict (id) do nothing;

-- ---------- Pedidos que llegan desde la tienda ----------
create sequence if not exists pedido_web_seq;
create table if not exists pedidos_web (
  id bigint generated always as identity primary key,
  codigo text unique not null default ('W-' || lpad(nextval('pedido_web_seq')::text, 3, '0')),
  creado timestamptz not null default now(),
  cliente text not null,
  telefono text not null,
  notas text,
  metodo_pago text,
  mayor boolean not null default false,
  total_usd numeric not null,
  tasa_bcv numeric,
  tasa_binance numeric,
  estado text not null default 'nuevo' check (estado in ('nuevo','confirmado','cancelado')),
  atendido_por text,
  atendido date
);
create table if not exists pedidos_web_items (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_web(id) on delete cascade,
  perfume_id bigint not null references perfumes(id),
  unidades int not null check (unidades > 0),
  precio_unit numeric not null check (precio_unit >= 0)
);

-- ---------- Perfumes agotados que la gente quiere (sirve para decidir qué comprar) ----------
create table if not exists demanda_web (
  id bigint generated always as identity primary key,
  creado timestamptz not null default now(),
  perfume_id bigint not null references perfumes(id) on delete cascade,
  cliente text not null,
  telefono text not null,
  unidades int not null default 1 check (unidades > 0),
  atendido boolean not null default false
);

-- ---------- Seguridad: las tablas solo las ven los socios ----------
do $$
declare t text;
begin
  foreach t in array array['tienda_config','pedidos_web','pedidos_web_items','demanda_web'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
  end loop;
end $$;

-- =====================================================================
-- FUNCIONES PÚBLICAS (las usa la tienda sin iniciar sesión).
-- Solo devuelven lo que se puede mostrar: nombre, precio, disponibilidad y foto.
-- Nunca costos, ganancias, clientes ni deudas.
-- =====================================================================

-- Unidades disponibles para la tienda = compradas − vendidas − apartadas por pedidos web nuevos
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int, foto_url text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         greatest(coalesce(c.u, 0) - coalesce(v.u, 0) - coalesce(w.u, 0), 0)::int,
         pf.foto_url
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id
  where pf.visible_tienda and pf.precio_detal is not null
  order by pf.nombre;
$$;

create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'tasa', (select to_jsonb(t) from (select fecha, bcv, binance from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

-- Crear un pedido desde la tienda. Los precios se calculan aquí (el navegador no puede cambiarlos).
create or replace function tienda_crear_pedido(
  p_cliente text, p_telefono text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int;
begin
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 80 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);          -- evita que dos personas aparten la misma última unidad
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;

  select bcv, binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance)
  values (trim(p_cliente), trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance)
  returning id, codigo into pid, ped_codigo;

  for it in select * from jsonb_array_elements(agg) loop
    pf := (it ->> 'perfume_id')::bigint; u := (it ->> 'unidades')::int;
    if u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select c.stock, case when mayor then c.precio_mayor else c.precio_detal end
      into disp, pu from tienda_catalogo() c where c.id = pf;
    if disp is null then raise exception 'Ese perfume ya no está disponible'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;

-- "Agendar pedido" de un perfume agotado: queda como demanda, no aparta ni cobra nada
create or replace function tienda_agendar(p_perfume_id bigint, p_cliente text, p_telefono text, p_unidades int)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 80 then raise exception 'Escribe tu nombre'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if coalesce(p_unidades, 0) not between 1 and 60 then raise exception 'Cantidad no válida'; end if;
  if not exists (select 1 from perfumes where id = p_perfume_id and visible_tienda) then raise exception 'Ese perfume no existe'; end if;
  -- evita duplicados del mismo teléfono para el mismo perfume pendiente
  if exists (select 1 from demanda_web where perfume_id = p_perfume_id and not atendido
             and regexp_replace(telefono, '\D', '', 'g') = regexp_replace(p_telefono, '\D', '', 'g')) then
    update demanda_web set unidades = p_unidades, cliente = trim(p_cliente)
    where perfume_id = p_perfume_id and not atendido and regexp_replace(telefono, '\D', '', 'g') = regexp_replace(p_telefono, '\D', '', 'g');
  else
    insert into demanda_web (perfume_id, cliente, telefono, unidades) values (p_perfume_id, trim(p_cliente), trim(p_telefono), p_unidades);
  end if;
end $$;

-- Permisos: la tienda (rol anon) solo puede ejecutar estas funciones
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'tienda_info()',
      'tienda_crear_pedido(text,text,text,text,jsonb)', 'tienda_agendar(bigint,text,text,int)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- =====================================================================
-- FUNCIONES DE LOS SOCIOS
-- =====================================================================

-- Confirmar un pedido web: lo convierte en ventas (sale del pedido más antiguo con stock) y aparecen en Por cobrar
create or replace function confirmar_pedido_web(p_id bigint, p_vendedor text) returns text
language plpgsql security invoker set search_path = public as $$
declare
  p pedidos_web%rowtype; it record; s record; falta int; toma int;
  tb numeric; tn numeric;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  if coalesce(trim(p_vendedor), '') = '' then raise exception 'Elige quién atiende el pedido'; end if;
  select bcv, binance into tb, tn from tasas order by fecha desc limit 1;
  tb := coalesce(p.tasa_bcv, tb); tn := coalesce(p.tasa_binance, tn);
  if tb is null or tn is null then raise exception 'Registra primero la tasa del día'; end if;

  for it in select * from pedidos_web_items where pedido_id = p.id order by id loop
    falta := it.unidades;
    for s in select pedido_codigo, restante from stock_pedido_v
             where perfume_id = it.perfume_id and restante > 0 order by fecha, pedido_codigo loop
      exit when falta <= 0;
      toma := least(falta, s.restante);
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, s.pedido_codigo, toma, it.precio_unit, 'divisa', tb, tn, 'Pedido web ' || p.codigo);
      falta := falta - toma;
    end loop;
    if falta > 0 then   -- sin stock en los pedidos: queda como venta anticipada
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, null, falta, it.precio_unit, 'divisa', tb, tn, 'Pedido web ' || p.codigo);
    end if;
  end loop;

  update clientes set telefono = p.telefono
  where lower(trim(nombre)) = lower(trim(p.cliente)) and coalesce(telefono, '') = '';
  update pedidos_web set estado = 'confirmado', atendido_por = p_vendedor, atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- Cancelar un pedido web: las unidades vuelven a estar disponibles en la tienda
create or replace function cancelar_pedido_web(p_id bigint) returns text
language plpgsql security invoker set search_path = public as $$
declare p pedidos_web%rowtype;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  update pedidos_web set estado = 'cancelado', atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- =====================================================================
-- FOTOS: carpeta pública "perfumes" en Supabase Storage (solo los socios pueden subir)
-- =====================================================================
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public) values ('perfumes', 'perfumes', true) on conflict (id) do nothing;
    execute 'drop policy if exists fotos_ver on storage.objects';
    execute 'drop policy if exists fotos_subir on storage.objects';
    execute 'drop policy if exists fotos_cambiar on storage.objects';
    execute 'drop policy if exists fotos_borrar on storage.objects';
    execute $p$create policy fotos_ver on storage.objects for select using (bucket_id = 'perfumes')$p$;
    execute $p$create policy fotos_subir on storage.objects for insert to authenticated with check (bucket_id = 'perfumes' and public.es_socio())$p$;
    execute $p$create policy fotos_cambiar on storage.objects for update to authenticated using (bucket_id = 'perfumes' and public.es_socio())$p$;
    execute $p$create policy fotos_borrar on storage.objects for delete to authenticated using (bucket_id = 'perfumes' and public.es_socio())$p$;
  end if;
end $$;

-- >>>>>>>>>> migracion_v5.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V5 · Tienda con banners, 2 fotos por perfume y datos de entrega.
-- Ejecútala UNA VEZ en el SQL Editor, después de migracion_v4.sql.
-- Es segura de repetir.
-- =====================================================================

-- ---------- Segunda foto del perfume ----------
alter table perfumes add column if not exists foto2_url text;

-- ---------- Banners del inicio de la tienda (máximo 4) ----------
create table if not exists tienda_banners (
  id int generated always as identity primary key,
  orden int not null unique check (orden between 1 and 4),
  url text not null,
  activo boolean not null default true
);
alter table tienda_banners enable row level security;
drop policy if exists solo_socios on tienda_banners;
create policy solo_socios on tienda_banners for all using (es_socio()) with check (es_socio());

-- ---------- Datos de quien pide: apellido va dentro de "cliente"; además dónde está y si quiere delivery ----------
alter table pedidos_web add column if not exists ubicacion text;
alter table pedidos_web add column if not exists delivery boolean not null default false;
alter table pedidos_web add column if not exists entrega_en text;

-- ---------- Ajustes: tu WhatsApp y el nombre de la tienda ----------
update tienda_config set whatsapp = '584241735215' where id = 1 and coalesce(whatsapp, '') = '';
update tienda_config set nombre = 'MOTOSA PARFUM' where id = 1 and nombre in ('Perfumes', 'Refreskitos');

-- =====================================================================
-- FUNCIONES PÚBLICAS (la tienda, sin iniciar sesión)
-- =====================================================================
drop function if exists tienda_catalogo();
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         greatest(coalesce(c.u, 0) - coalesce(v.u, 0) - coalesce(w.u, 0), 0)::int,
         pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id
  where pf.visible_tienda and pf.precio_detal is not null
  order by pf.nombre;
$$;

create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'banners', coalesce((select jsonb_agg(b.url order by b.orden) from tienda_banners b where b.activo), '[]'::jsonb),
    'tasa', (select to_jsonb(t) from (select fecha, bcv, binance from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

-- Pedido nuevo: ahora pide nombre, apellido, teléfono, dónde está y si necesita delivery (y hasta dónde)
drop function if exists tienda_crear_pedido(text, text, text, text, jsonb);
create or replace function tienda_crear_pedido(
  p_nombre text, p_apellido text, p_telefono text, p_ubicacion text,
  p_delivery boolean, p_entrega text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int; cli text;
begin
  if char_length(trim(coalesce(p_nombre, ''))) not between 2 and 40 then raise exception 'Escribe tu nombre'; end if;
  if char_length(trim(coalesce(p_apellido, ''))) not between 2 and 40 then raise exception 'Escribe tu apellido'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if char_length(trim(coalesce(p_ubicacion, ''))) not between 3 and 120 then raise exception 'Cuéntanos en qué zona o ciudad te encuentras'; end if;
  if coalesce(p_delivery, false) and char_length(trim(coalesce(p_entrega, ''))) not between 3 and 200 then
    raise exception 'Escribe hasta dónde necesitas el delivery';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;
  cli := trim(p_nombre) || ' ' || trim(p_apellido);

  select bcv, binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance, ubicacion, delivery, entrega_en)
  values (cli, trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance,
          trim(p_ubicacion), coalesce(p_delivery, false), case when coalesce(p_delivery, false) then trim(p_entrega) end)
  returning id, codigo into pid, ped_codigo;

  for it in select * from jsonb_array_elements(agg) loop
    pf := (it ->> 'perfume_id')::bigint; u := (it ->> 'unidades')::int;
    if u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select c.stock, case when mayor then c.precio_mayor else c.precio_detal end
      into disp, pu from tienda_catalogo() c where c.id = pf;
    if disp is null then raise exception 'Ese perfume ya no está disponible'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;

-- Permisos: la tienda (rol anon) solo ejecuta estas funciones
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'tienda_info()',
      'tienda_crear_pedido(text,text,text,text,boolean,text,text,text,jsonb)', 'tienda_agendar(bigint,text,text,int)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- Confirmar un pedido web: igual que antes, y la nota de cada venta guarda si era delivery
create or replace function confirmar_pedido_web(p_id bigint, p_vendedor text) returns text
language plpgsql security invoker set search_path = public as $$
declare
  p pedidos_web%rowtype; it record; s record; falta int; toma int;
  tb numeric; tn numeric; nota text;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  if coalesce(trim(p_vendedor), '') = '' then raise exception 'Elige quién atiende el pedido'; end if;
  select bcv, binance into tb, tn from tasas order by fecha desc limit 1;
  tb := coalesce(p.tasa_bcv, tb); tn := coalesce(p.tasa_binance, tn);
  if tb is null or tn is null then raise exception 'Registra primero la tasa del día'; end if;
  nota := 'Pedido web ' || p.codigo || case when p.delivery then ' · Delivery: ' || coalesce(p.entrega_en, '') else '' end;

  for it in select * from pedidos_web_items where pedido_id = p.id order by id loop
    falta := it.unidades;
    for s in select pedido_codigo, restante from stock_pedido_v
             where perfume_id = it.perfume_id and restante > 0 order by fecha, pedido_codigo loop
      exit when falta <= 0;
      toma := least(falta, s.restante);
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, s.pedido_codigo, toma, it.precio_unit, 'divisa', tb, tn, nota);
      falta := falta - toma;
    end loop;
    if falta > 0 then
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, null, falta, it.precio_unit, 'divisa', tb, tn, nota);
    end if;
  end loop;

  update clientes set telefono = p.telefono
  where lower(trim(nombre)) = lower(trim(p.cliente)) and coalesce(telefono, '') = '';
  update pedidos_web set estado = 'confirmado', atendido_por = p_vendedor, atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- >>>>>>>>>> migracion_v6.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V6 · Una sola tasa de venta: BCV Euro.
--  · La tasa BCV Euro (Bs por €) es la que ven los clientes en la tienda y la que usan
--    las ventas nuevas para convertir $ <-> Bs.
--  · La tasa Binance queda SOLO como dato interno (valorar la caja y comprar divisas
--    para recomprar mercancía). La tienda pública ya no la recibe.
--  · Ya no se pide el dólar BCV. Las filas antiguas se conservan.
-- Ejecútala UNA VEZ después de migracion_v5.sql. Es segura de repetir.
-- =====================================================================
alter table tasas add column if not exists euro numeric check (euro > 0);
alter table tasas alter column bcv drop not null;

-- La tienda solo recibe la tasa de venta (BCV Euro); nunca la Binance
create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'banners', coalesce((select jsonb_agg(b.url order by b.orden) from tienda_banners b where b.activo), '[]'::jsonb),
    'tasa', (select to_jsonb(t) from (select fecha, coalesce(euro, bcv) as euro from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

-- Pedidos web: guardan la tasa de venta (BCV Euro) con la que se cotizó
create or replace function tienda_crear_pedido(
  p_nombre text, p_apellido text, p_telefono text, p_ubicacion text,
  p_delivery boolean, p_entrega text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int; cli text;
begin
  if char_length(trim(coalesce(p_nombre, ''))) not between 2 and 40 then raise exception 'Escribe tu nombre'; end if;
  if char_length(trim(coalesce(p_apellido, ''))) not between 2 and 40 then raise exception 'Escribe tu apellido'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if char_length(trim(coalesce(p_ubicacion, ''))) not between 3 and 120 then raise exception 'Cuéntanos en qué zona o ciudad te encuentras'; end if;
  if coalesce(p_delivery, false) and char_length(trim(coalesce(p_entrega, ''))) not between 3 and 200 then
    raise exception 'Escribe hasta dónde necesitas el delivery';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;
  cli := trim(p_nombre) || ' ' || trim(p_apellido);

  select coalesce(euro, bcv) as bcv, coalesce(euro, bcv) as binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance, ubicacion, delivery, entrega_en)
  values (cli, trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance,
          trim(p_ubicacion), coalesce(p_delivery, false), case when coalesce(p_delivery, false) then trim(p_entrega) end)
  returning id, codigo into pid, ped_codigo;

  for it in select * from jsonb_array_elements(agg) loop
    pf := (it ->> 'perfume_id')::bigint; u := (it ->> 'unidades')::int;
    if u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select c.stock, case when mayor then c.precio_mayor else c.precio_detal end
      into disp, pu from tienda_catalogo() c where c.id = pf;
    if disp is null then raise exception 'Ese perfume ya no está disponible'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;


-- Confirmar pedido web: las ventas usan la tasa de venta guardada en el pedido
create or replace function confirmar_pedido_web(p_id bigint, p_vendedor text) returns text
language plpgsql security invoker set search_path = public as $$
declare
  p pedidos_web%rowtype; it record; s record; falta int; toma int;
  tb numeric; tn numeric; nota text;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_web where id = p_id for update;
  if not found then raise exception 'El pedido no existe'; end if;
  if p.estado <> 'nuevo' then raise exception 'El pedido % ya está %', p.codigo, p.estado; end if;
  if coalesce(trim(p_vendedor), '') = '' then raise exception 'Elige quién atiende el pedido'; end if;
  select coalesce(euro, bcv), coalesce(euro, bcv) into tb, tn from tasas order by fecha desc limit 1;
  tb := coalesce(p.tasa_bcv, tb); tn := coalesce(p.tasa_binance, tn);
  if tb is null or tn is null then raise exception 'Registra primero la tasa del día'; end if;
  nota := 'Pedido web ' || p.codigo || case when p.delivery then ' · Delivery: ' || coalesce(p.entrega_en, '') else '' end;

  for it in select * from pedidos_web_items where pedido_id = p.id order by id loop
    falta := it.unidades;
    for s in select pedido_codigo, restante from stock_pedido_v
             where perfume_id = it.perfume_id and restante > 0 order by fecha, pedido_codigo loop
      exit when falta <= 0;
      toma := least(falta, s.restante);
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, s.pedido_codigo, toma, it.precio_unit, 'divisa', tb, tn, nota);
      falta := falta - toma;
    end loop;
    if falta > 0 then
      insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
      values (current_date, p.cliente, p_vendedor, it.perfume_id, null, falta, it.precio_unit, 'divisa', tb, tn, nota);
    end if;
  end loop;

  update clientes set telefono = p.telefono
  where lower(trim(nombre)) = lower(trim(p.cliente)) and coalesce(telefono, '') = '';
  update pedidos_web set estado = 'confirmado', atendido_por = p_vendedor, atendido = current_date where id = p.id;
  return p.codigo;
end $$;

-- >>>>>>>>>> migracion_v7.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V7 · La tienda muestra TODOS los perfumes.
-- Antes solo salían los que tenían "precio al detal" cargado, por eso faltaban los
-- demás. Ahora salen todos (con foto a color, haya o no stock). Los que todavía no
-- tienen precio salen como "Precio por confirmar" y se pueden agendar, pero no se
-- compran online hasta que les pongas precio en Inventario.
-- NO modifica ni borra nada de lo que ya cargaste.
-- Ejecútala UNA VEZ después de migracion_v6.sql. Es segura de repetir.
-- =====================================================================
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         greatest(coalesce(c.u, 0) - coalesce(v.u, 0) - coalesce(w.u, 0), 0)::int,
         pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.nombre;
$$;

-- Un perfume sin precio no se puede comprar online (solo agendar)
create or replace function tienda_crear_pedido(
  p_nombre text, p_apellido text, p_telefono text, p_ubicacion text,
  p_delivery boolean, p_entrega text, p_notas text, p_metodo text, p_items jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  agg jsonb; it jsonb; umbral int; unid_total int; mayor boolean; total numeric := 0;
  disp int; pu numeric; pid bigint; ped_codigo text; t record; pf bigint; u int; cli text;
begin
  if char_length(trim(coalesce(p_nombre, ''))) not between 2 and 40 then raise exception 'Escribe tu nombre'; end if;
  if char_length(trim(coalesce(p_apellido, ''))) not between 2 and 40 then raise exception 'Escribe tu apellido'; end if;
  if char_length(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g')) not between 7 and 15 then raise exception 'Escribe un teléfono válido'; end if;
  if char_length(trim(coalesce(p_ubicacion, ''))) not between 3 and 120 then raise exception 'Cuéntanos en qué zona o ciudad te encuentras'; end if;
  if coalesce(p_delivery, false) and char_length(trim(coalesce(p_entrega, ''))) not between 3 and 200 then
    raise exception 'Escribe hasta dónde necesitas el delivery';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Tu carrito está vacío';
  end if;

  perform pg_advisory_xact_lock(884422);
  select umbral_mayor into umbral from tienda_config where id = 1;

  select jsonb_agg(jsonb_build_object('perfume_id', perfume_id, 'unidades', unidades)), sum(unidades)
    into agg, unid_total
  from (select (x ->> 'perfume_id')::bigint as perfume_id, sum((x ->> 'unidades')::int)::int as unidades
        from jsonb_array_elements(p_items) x group by 1) g;
  mayor := unid_total >= umbral;
  cli := trim(p_nombre) || ' ' || trim(p_apellido);

  select coalesce(euro, bcv) as bcv, coalesce(euro, bcv) as binance into t from tasas order by fecha desc limit 1;
  insert into pedidos_web (cliente, telefono, notas, metodo_pago, mayor, total_usd, tasa_bcv, tasa_binance, ubicacion, delivery, entrega_en)
  values (cli, trim(p_telefono), nullif(trim(p_notas), ''), nullif(trim(p_metodo), ''), mayor, 0, t.bcv, t.binance,
          trim(p_ubicacion), coalesce(p_delivery, false), case when coalesce(p_delivery, false) then trim(p_entrega) end)
  returning id, codigo into pid, ped_codigo;

  for it in select * from jsonb_array_elements(agg) loop
    pf := (it ->> 'perfume_id')::bigint; u := (it ->> 'unidades')::int;
    if u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select c.stock, case when mayor then c.precio_mayor else c.precio_detal end
      into disp, pu from tienda_catalogo() c where c.id = pf;
    if disp is null then raise exception 'Ese perfume ya no está disponible'; end if;
    if pu is null then raise exception 'Ese perfume todavía no tiene precio: agéndalo y te avisamos'; end if;
    if u > disp then
      raise exception 'Solo quedan % de %', disp, (select nombre from perfumes where id = pf);
    end if;
    insert into pedidos_web_items (pedido_id, perfume_id, unidades, precio_unit) values (pid, pf, u, pu);
    total := total + pu * u;
  end loop;

  update pedidos_web set total_usd = total where id = pid;
  return jsonb_build_object('codigo', ped_codigo, 'total', total, 'mayor', mayor);
end $$;

-- >>>>>>>>>> TASAS DE HOY <<<<<<<<<<
do $$
declare
  -- ===== EDITA ESTAS 3 CIFRAS (Bs por unidad; usa punto para decimales, ej. 1030.50) =====
  v_euro    numeric := NULL;   -- BCV Euro
  v_binance numeric := NULL;   -- Binance
  v_bcv     numeric := NULL;   -- BCV $ (dólar)
  -- ======================================================================================
begin
  if coalesce(v_euro, 0) <= 0 or coalesce(v_binance, 0) <= 0 or coalesce(v_bcv, 0) <= 0 then
    raise exception 'Falta escribir las 3 tasas de hoy (BCV Euro, Binance y BCV $) en el bloque "EDITA ESTAS 3 CIFRAS".';
  end if;
  insert into tasas (fecha, euro, binance, bcv) values (current_date, v_euro, v_binance, v_bcv)
  on conflict (fecha) do update set euro = excluded.euro, binance = excluded.binance, bcv = excluded.bcv;
end $$;

-- >>>>>>>>>> migracion_v8.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V8 · Gastos, rentabilidad y carga del LOTE 3 (ventas y cobros)
-- Ejecutar DESPUÉS de migracion_v7.sql. No borra ni cambia lo ya cargado.
-- Las partes de CARGA se aplican UNA sola vez (se anotan en cargas_hechas),
-- así que si la repites no duplica ventas ni cobros.
-- =====================================================================

-- ---------- 1. GASTOS (delivery, traslados, empaques, etc.) ----------
create table if not exists gastos (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  categoria text not null default 'otro'
    check (categoria in ('delivery','traslado','empaque','publicidad','comision','otro')),
  concepto text not null,
  monto numeric not null check (monto > 0),                       -- siempre en $
  pedido_codigo text references pedidos(codigo) on update cascade on delete set null,  -- vacío = gasto general
  cuenta text check (cuenta in ('binance','efectivo')),           -- de qué caja salió; vacío = lo puso un socio
  pagado_por text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table gastos enable row level security;
drop policy if exists solo_socios on gastos;
create policy solo_socios on gastos for all using (es_socio()) with check (es_socio());

-- Control interno de cargas únicas
create table if not exists cargas_hechas (clave text primary key, hecho timestamptz not null default now());
alter table cargas_hechas enable row level security;
drop policy if exists solo_socios on cargas_hechas;
create policy solo_socios on cargas_hechas for all using (es_socio()) with check (es_socio());

-- La agenda puede llevar una nota (quién lo vendió, detalles)
alter table agenda_pedidos add column if not exists nota text;

-- Un gasto pagado desde la caja baja el saldo de esa cuenta
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
) x group by cuenta;

-- ---------- 2. RENTABILIDAD ----------
-- Por pedido: ganancia bruta (vendido − costo), gastos del pedido y ganancia neta
create or replace view rentabilidad_pedido_v with (security_invoker = true) as
select g.codigo, g.fecha, g.inversion, g.ventas_usd, g.cobrado_usd, g.pendiente_usd,
       g.costo_vendido, g.ganancia as ganancia_bruta,
       coalesce(x.gastos, 0) as gastos,
       g.ganancia - coalesce(x.gastos, 0) as ganancia_neta
from ganancia_pedido_v g
left join (select pedido_codigo, sum(monto) gastos from gastos where pedido_codigo is not null group by pedido_codigo) x
  on x.pedido_codigo = g.codigo;

-- Por socio: cada pedido reparte (ganancia − gastos del pedido) según la participación de cada socio
create or replace view rentabilidad_socios_v with (security_invoker = true) as
select ps.socio,
       sum(ps.aporte) as aportes,
       sum(r.ganancia_bruta * ps.participacion) as ganancia_bruta,
       sum(r.gastos * ps.participacion) as gastos,
       sum(r.ganancia_neta * ps.participacion) as ganancia_neta
from pedido_socios ps
join rentabilidad_pedido_v r on r.codigo = ps.pedido_codigo
group by ps.socio;

-- =====================================================================
-- 3. CARGA DEL LOTE 3  (una sola vez)
-- =====================================================================
-- Busca un perfume por nombre exacto o, si tu catálogo lo tiene escrito distinto, por una parte del nombre
create or replace function v8_buscar_perfume(p_nombre text, p_patron text) returns bigint
language sql stable as $f$
  select id from perfumes
  where lower(trim(nombre)) = lower(trim(p_nombre)) or nombre ~* p_patron
  order by (lower(trim(nombre)) = lower(trim(p_nombre))) desc, length(nombre), id
  limit 1
$f$;

do $$
declare
  tv numeric; tb numeric; faltan text;
  v_id bigint; pid bigint; r record; cod text;
begin
  if exists (select 1 from cargas_hechas where clave = 'v8_lote3') then
    raise notice 'La carga del lote 3 ya se había aplicado: no se repite.';
    return;
  end if;

  -- Tasa de venta (BCV Euro, o BCV si no hay euro) y Binance del día más reciente
  select coalesce(euro, bcv), binance into tv, tb from tasas order by fecha desc limit 1;
  if tv is null then raise exception 'Primero registra la tasa de hoy en la pestaña Tasas y vuelve a ejecutar esto.'; end if;

  -- ---- 3.1 Cambio de Moschino (no llegó) por Bharara Viking en el pedido P-003 ----
  if v8_buscar_perfume('Bharara Viking', 'viking') is null then insert into perfumes (nombre) values ('Bharara Viking'); end if;
  update compras set perfume_id = v8_buscar_perfume('Bharara Viking', 'viking')
  where pedido_codigo = 'P-003'
    and perfume_id = v8_buscar_perfume('Moschino Toy Boy', 'moschino');

  -- ---- 3.2 Perfumes que no estaban en el catálogo ----
  if v8_buscar_perfume('Lattafa Yara Moi', 'yara.*moi') is null then insert into perfumes (nombre) values ('Lattafa Yara Moi'); end if;
  if v8_buscar_perfume('Mont Blanc Legend Spirit', 'legend.*spirit') is null then insert into perfumes (nombre) values ('Mont Blanc Legend Spirit'); end if;

  -- ---- 3.3 Ventas del lote 3 ----
  -- (cliente, vendedor, perfume, unidades, precio_unit $, vence, nota, cobrado ahora en efectivo)
  drop table if exists pg_temp._v8_lote3;
  create temp table _v8_lote3 (cliente text, vendedor text, perfume text, unid int, precio numeric,
                        vence date, nota text, cobrado numeric, pedido text, patron text) on commit drop;
  insert into _v8_lote3 values
   ('Lory Teran',        'Juan',    'Ariana Grande Cloud',                     1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'cloud'),
   ('Lory Teran',        'Juan',    'Ariana Grande Mod Blush',                 1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'mod blush'),
   ('Elvys Castillo',    'Juan',    'Victorinox',                              1, 25, '2026-10-30', 'Swiss Army Classic. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'victorinox|swiss army'),
   ('Rosalba Montilva',  'Juan',    'Lancome La Vie Est Belle',       1, 25, '2026-10-30', 'Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'la vie est belle'),
   ('Carola Carvajal',   'George',  'Armaf Odyssey Mandarin Sky Elixir',       1, 30, '2026-10-30', 'Con Yara Moi: total $60. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'mandari[n]e? sky'),
   ('Carola Carvajal',   'George',  'Lattafa Yara Moi',                        1, 30, '2026-10-30', 'Con Mandarin Sky: total $60. Pagará 50% el 30/10 y 50% el 15/11. REVISAR: Yara Moi no está en las compras del lote 3', 0, 'P-003', 'yara.*moi'),
   ('Rosalba Guitian',   'Rosanny', 'Carolina Herrera Good Girl Fem',          1, 30, '2026-10-30', 'Precio $30 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'good girl'),
   ('Jhoanny',           'Rosanny', 'Lattafa Yara Candy Fem',                  1, 35, '2026-10-30', 'Precio $35 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', 'yara candy'),
   ('Dra. Yexy',         'Juan',    'Victoria Secret Splash 250ml (variados)', 2, 7.5,'2026-10-30', 'Splash Coconut ×2 (total $15). Paga el 30/10', 0, 'P-003', 'splash'),
   ('Juan Teran',        'Juan',    'Victoria Secret Splash 250ml (variados)', 2, 7.5,'2026-10-30', 'Splash Juice Berry ×2 (total $15). Paga el 30/10', 0, 'P-003', 'splash'),
   ('Keylin Cabrera',    'Juan',    'Ariana Grande Thank U Next',              1, 25, null,         'Pagó en efectivo', 25, 'P-003', 'thank u next'),
   ('Juan Teran',        'Juan',    '9 PM Night Out',                          1, 35, '2026-10-30', 'Precio $35 BCV. Paga el 30/10', 0, 'P-003', '9 ?pm'),
   ('Almari',            'Rosanny', 'Lattafa Yara Fem',                        1, 35, '2026-10-30', 'Yara Clásico, precio $35 BCV. Pagará 50% el 30/10 y 50% el 15/11', 0, 'P-003', '^(lattafa )?yara( fem)?( cl.sic[oa])?$'),
   ('Jesus Teran',       'Juan',    'One Million Paco Rabanne',                1, 20, '2026-10-30', 'Pagará el 30/10 y el 15/11 (mitad y mitad)', 0, 'P-003', 'one million'),
   ('Jesus Teran',       'Juan',    'Bestia Negra',                            1, 20, '2026-10-30', 'Club de Nuit. Pagará el 30/10 y el 15/11 (mitad y mitad)', 0, 'P-003', 'bestia negra|club de nuit'),
   -- Reserva sin stock: venta anticipada (se descuenta cuando llegue la compra)
   ('Mauricio Garcez',   'Juan',    'Mont Blanc Legend Spirit',                1, 25, null,         'Reserva: pagó $10, debe $15. Hay que comprarlo (está en la Agenda)', 10, null, 'legend.*spirit');

  select string_agg(distinct perfume, ', ') into faltan from _v8_lote3 where v8_buscar_perfume(perfume, patron) is null;
  if faltan is not null then raise exception 'No encuentro estos perfumes en tu catálogo: %. Avísame cómo se llaman y lo ajusto.', faltan; end if;

  for r in select * from _v8_lote3 loop
    pid := v8_buscar_perfume(r.perfume, r.patron);
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base,
                        tasa_bcv, tasa_binance, vence, nota)
    values ('2026-10-24', r.cliente, r.vendedor, pid, r.pedido, r.unid, r.precio, 'divisa', tv, tv, r.vence, r.nota)
    returning id into v_id;
    if r.cobrado > 0 then
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-24', 'efectivo', r.cobrado);
    end if;
  end loop;

  -- ---- 3.4 Pagos recibidos sobre ventas que ya estaban registradas ----
  -- Luisa Teran: $25 por el Afnan 9am (efectivo)
  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'luisa teran%' and pf.nombre ilike '%9am%' order by v.id desc limit 1;
  if v_id is null then raise notice 'REVISAR: no encontré la venta del 9am de Luisa Teran; registra su pago de $25 a mano.';
  else insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-24', 'efectivo', 25); end if;

  -- Anny Guitian: mitad de los splash ($7,50) pagada en Bs a tasa BCV
  select v.id into v_id from ventas v join perfumes pf on pf.id = v.perfume_id
   where lower(v.cliente) like 'anny guitian%' and pf.nombre ilike '%splash%' order by v.id desc limit 1;
  if v_id is null then raise notice 'REVISAR: no encontré la venta de splash de Anny Guitian; registra su pago de $7,50 a mano.';
  else insert into cobros (venta_id, fecha, cuenta, monto, tasa_binance)
       values (v_id, '2026-10-24', 'bs', round(7.5 * tv, 2), tv); end if;

  -- ---- 3.5 Agenda: perfumes por comprar (los costos son estimados con los del lote 3; edítalos en Agenda) ----
  select 'A-' || lpad((count(*) + 1)::text, 3, '0') into cod from agenda_pedidos;
  while exists (select 1 from agenda_pedidos where codigo = cod) or exists (select 1 from pedidos where codigo = cod) loop
    cod := 'A-' || lpad((substr(cod, 3)::int + 1)::text, 3, '0');
  end loop;
  insert into agenda_pedidos (codigo, fecha_prevista, proveedor, envio, registrado, nota)
  values (cod, null, null, 0, false,
          'Pendientes por comprar. Splash: 1 Pure Seduction + 1 Vainilla Lace. Los vendió Wilesmar. Incluye la reserva de Mauricio Garcez (Mont Blanc Legend Spirit).');
  insert into agenda_socios (codigo, socio, aporte) select cod, nombre, 0 from socios;
  insert into agenda_lineas (codigo, nombre, unidades, costo_unitario, precio_detal) values
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Carolina Herrera 212 VIP', '212 vip')), 'Carolina Herrera 212 VIP'), 2, 11, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Lattafa Yara Fem', '^(lattafa )?yara( fem)?( cl.sic[oa])?$')), 'Lattafa Yara Fem'), 1, 12, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Armaf Odyssey Mandarin Sky Elixir', 'mandari[n]e? sky')), 'Armaf Odyssey Mandarin Sky Elixir'), 1, 13, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Bestia Negra', 'bestia negra|club de nuit')), 'Bestia Negra'), 1, 12, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('9 PM Night Out', '9 ?pm')), '9 PM Night Out'), 1, 13, null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Victoria Secret Splash 250ml (variados)', 'splash')), 'Victoria Secret Splash 250ml (variados)'), 2, 3,  null),
    (cod, coalesce((select nombre from perfumes where id = v8_buscar_perfume('Mont Blanc Legend Spirit', 'legend.*spirit')), 'Mont Blanc Legend Spirit'), 1, 13, null);

  insert into cargas_hechas (clave) values ('v8_lote3');
  raise notice 'Lote 3 cargado: % ventas. Agenda creada: %', (select count(*) from _v8_lote3), cod;
end $$;

drop function if exists v8_buscar_perfume(text, text);

-- >>>>>>>>>> migracion_v9.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN V9 · Catálogo (perfumes con o sin inventario) y Vendedoras
-- Ejecutar DESPUÉS de migracion_v8.sql. No borra ni cambia datos existentes.
-- Es segura de repetir.
--
-- CATÁLOGO: cada perfume tiene 3 precios que no se mezclan:
--   precio_detal     -> lo que paga el público en la tienda online
--   precio_mayor     -> lo que paga el público al comprar el mayor (12 perfumes)
--   precio_consigna  -> lo que te debe una vendedora por cada perfume que vende
-- La tienda NUNCA recibe la consignación ni el costo; las vendedoras NUNCA ven el
-- precio al mayor ni el costo.
--
-- VENDEDORAS: entran a un link aparte con usuario + PIN (6 a 10 números), eligen
-- del catálogo, anotan a cuánto vendieron (nunca menos que la consignación) y tú
-- apruebas cada pedido. Al aprobar, se crea la venta a precio de consignación.
-- =====================================================================

-- ---------- 1. Catálogo: campos nuevos en perfumes ----------
alter table perfumes add column if not exists descripcion text;
alter table perfumes add column if not exists precio_consigna numeric check (precio_consigna >= 0);
alter table perfumes add column if not exists existencia_manual int check (existencia_manual >= 0);
alter table perfumes add column if not exists visible_vendedoras boolean not null default true;

-- Existencia real de cada perfume (la misma regla para la tienda y para las vendedoras):
--  * Si tiene compras registradas: compras − ventas − pedidos web nuevos.
--  * Si NO tiene compras (solo está en el catálogo): la existencia que anotes a mano − pedidos web nuevos.
create or replace function stock_efectivo()
returns table (perfume_id bigint, stock int, en_inventario boolean)
language sql stable security definer set search_path = public as $$
  select pf.id,
         greatest(case when c.u is not null then c.u - coalesce(v.u, 0) else coalesce(pf.existencia_manual, 0) end
                  - coalesce(w.u, 0), 0)::int,
         c.u is not null
  from perfumes pf
  left join (select perfume_id, sum(unidades) u from compras group by perfume_id) c on c.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  left join (select i.perfume_id, sum(i.unidades) u from pedidos_web_items i
             join pedidos_web p on p.id = i.pedido_id where p.estado = 'nuevo' group by i.perfume_id) w on w.perfume_id = pf.id;
$$;

-- La tienda: ahora con descripción y con la existencia del catálogo
drop function if exists tienda_catalogo();
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.nombre;
$$;

-- ---------- 2. Vendedoras ----------
create table if not exists vendedoras (
  id bigint generated always as identity primary key,
  nombre text not null,
  usuario text not null unique,
  salt text not null default replace(gen_random_uuid()::text, '-', ''),
  pin_hash text,
  activa boolean not null default true,
  intentos int not null default 0,
  bloqueado_hasta timestamptz,
  creada timestamptz not null default now()
);

create table if not exists vendedora_sesiones (
  token_hash text primary key,
  vendedora_id bigint not null references vendedoras(id) on delete cascade,
  expira timestamptz not null
);

create table if not exists pedidos_vendedora (
  id bigint generated always as identity primary key,
  vendedora_id bigint not null references vendedoras(id),
  creado timestamptz not null default now(),
  cliente text not null,
  telefono text,
  notas text,
  plan text not null default 'contado' check (plan in ('contado','mitades','otro')),
  fecha1 date,
  fecha2 date,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado','entregado')),
  nota_admin text,
  aprobado_por text,
  aprobado_en timestamptz
);

create table if not exists pedidos_vendedora_items (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_vendedora(id) on delete cascade,
  perfume_id bigint not null references perfumes(id),
  unidades int not null check (unidades > 0),
  precio_consigna numeric not null check (precio_consigna >= 0),   -- se congela al anotar el pedido
  precio_venta numeric not null check (precio_venta >= 0),         -- a cuánto vendió ella
  venta_id bigint references ventas(id) on delete set null,        -- la venta que se crea al aprobar
  check (precio_venta >= precio_consigna)
);

-- Lo que el cliente le fue pagando a la vendedora
create table if not exists cobros_vendedora (
  id bigint generated always as identity primary key,
  pedido_id bigint not null references pedidos_vendedora(id) on delete cascade,
  fecha date not null default current_date,
  monto numeric not null check (monto > 0),
  quien text not null,
  nota text,
  creado timestamptz not null default now()
);

-- Seguridad: solo los socios ven estas tablas; las vendedoras entran únicamente por las funciones de abajo
do $$
declare t text;
begin
  foreach t in array array['vendedoras','vendedora_sesiones','pedidos_vendedora','pedidos_vendedora_items','cobros_vendedora'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists solo_socios on %I', t);
    if t <> 'vendedora_sesiones' then
      execute format('create policy solo_socios on %I for all using (es_socio()) with check (es_socio())', t);
    end if;
  end loop;
end $$;

-- Resumen por pedido de vendedora (lo usa el control y la app de vendedoras)
create or replace view vendedora_pedidos_v with (security_invoker = true) as
select p.id, p.vendedora_id, d.nombre as vendedora, p.creado, p.cliente, p.telefono, p.notas, p.plan, p.fecha1, p.fecha2,
       p.estado, p.nota_admin,
       coalesce(t.total_venta, 0) as total_venta,
       coalesce(t.total_consigna, 0) as total_consigna,
       coalesce(t.total_venta, 0) - coalesce(t.total_consigna, 0) as ganancia_vendedora,
       coalesce(c.cobrado, 0) as cobrado_cliente,
       coalesce(pg.pagado, 0) as pagado_perfumeria,
       case when p.estado in ('aprobado','entregado') and coalesce(t.total_venta, 0) > 0
            then greatest(least(coalesce(c.cobrado, 0), coalesce(t.total_consigna, 0)) - coalesce(pg.pagado, 0), 0)
            else 0 end as debe_perfumeria,
       -- la perfumería cobra primero su consignación; lo que pase de ahí es de la vendedora
       greatest(least(coalesce(c.cobrado, 0) - coalesce(t.total_consigna, 0), coalesce(t.total_venta, 0) - coalesce(t.total_consigna, 0)), 0) as ganancia_ganada
from pedidos_vendedora p
join vendedoras d on d.id = p.vendedora_id
left join (select pedido_id, sum(unidades * precio_venta) total_venta, sum(unidades * precio_consigna) total_consigna
           from pedidos_vendedora_items group by pedido_id) t on t.pedido_id = p.id
left join (select pedido_id, sum(monto) cobrado from cobros_vendedora group by pedido_id) c on c.pedido_id = p.id
left join (select i.pedido_id, sum(v.cobrado_usd) pagado
           from pedidos_vendedora_items i join ventas_v v on v.id = i.venta_id group by i.pedido_id) pg on pg.pedido_id = p.id;

-- ---------- 3. Funciones internas ----------
create or replace function vend_hash(p_texto text) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p_texto, ''), 'UTF8')), 'hex') $$;

-- Quién es la vendedora de esta sesión (o error si venció)
create or replace function vend_id(p_token text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  select s.vendedora_id into v
  from vendedora_sesiones s join vendedoras d on d.id = s.vendedora_id
  where s.token_hash = vend_hash(p_token) and s.expira > now() and d.activa;
  if v is null then raise exception 'Tu sesión venció. Entra de nuevo.'; end if;
  return v;
end $$;

-- ---------- 4. Funciones de la app de vendedoras (rol anon) ----------
-- Entrar con usuario + PIN. Tras 5 fallos seguidos se bloquea 15 minutos.
create or replace function vend_entrar(p_usuario text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d vendedoras%rowtype; tok text;
begin
  select * into d from vendedoras where usuario = lower(trim(coalesce(p_usuario, '')));
  if not found or not d.activa then
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'mensaje', 'Usuario o PIN incorrecto');
  end if;
  if d.bloqueado_hasta is not null and d.bloqueado_hasta > now() then
    return jsonb_build_object('ok', false, 'mensaje', 'Demasiados intentos. Prueba de nuevo en unos minutos.');
  end if;
  if d.pin_hash is null or d.pin_hash <> vend_hash(d.salt || ':' || coalesce(p_pin, '')) then
    update vendedoras set intentos = case when intentos + 1 >= 5 then 0 else intentos + 1 end,
                          bloqueado_hasta = case when intentos + 1 >= 5 then now() + interval '15 minutes' else bloqueado_hasta end
    where id = d.id;
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'mensaje', 'Usuario o PIN incorrecto');
  end if;
  update vendedoras set intentos = 0, bloqueado_hasta = null where id = d.id;
  delete from vendedora_sesiones where expira < now();
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into vendedora_sesiones (token_hash, vendedora_id, expira) values (vend_hash(tok), d.id, now() + interval '12 hours');
  return jsonb_build_object('ok', true, 'token', tok, 'nombre', d.nombre);
end $$;

-- El catálogo que ve la vendedora: SOLO consignación y precio sugerido (nunca costo ni precio al mayor)
create or replace function vend_catalogo(p_token text)
returns table (id bigint, nombre text, descripcion text, foto_url text, foto2_url text,
               precio_consigna numeric, precio_sugerido numeric, disponible boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return query
    select pf.id, pf.nombre, pf.descripcion, pf.foto_url, pf.foto2_url, pf.precio_consigna, pf.precio_detal, s.stock > 0
    from perfumes pf join stock_efectivo() s on s.perfume_id = pf.id
    where pf.visible_vendedoras and pf.precio_consigna is not null
    order by pf.nombre;
end $$;

-- Anotar un pedido (queda pendiente hasta que lo apruebes)
create or replace function vend_crear_pedido(
  p_token text, p_cliente text, p_telefono text, p_notas text, p_plan text, p_fecha1 date, p_fecha2 date, p_items jsonb
) returns bigint
language plpgsql security definer set search_path = public as $$
declare vid bigint; pid bigint; it jsonb; pf perfumes%rowtype; u int; pv numeric; n int;
begin
  vid := vend_id(p_token);
  if char_length(trim(coalesce(p_cliente, ''))) not between 2 and 60 then raise exception 'Escribe el nombre del cliente'; end if;
  if coalesce(trim(p_telefono), '') <> '' and char_length(regexp_replace(p_telefono, '\D', '', 'g')) not between 7 and 15 then
    raise exception 'El teléfono no es válido';
  end if;
  if p_plan not in ('contado','mitades','otro') then raise exception 'Elige cómo va a pagar el cliente'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 40 then
    raise exception 'Agrega al menos un perfume';
  end if;
  select count(*) into n from pedidos_vendedora where vendedora_id = vid and estado = 'pendiente';
  if n >= 30 then raise exception 'Tienes muchos pedidos esperando aprobación. Espera a que se revisen.'; end if;

  insert into pedidos_vendedora (vendedora_id, cliente, telefono, notas, plan, fecha1, fecha2)
  values (vid, trim(p_cliente), nullif(trim(p_telefono), ''), nullif(trim(p_notas), ''), p_plan, p_fecha1, p_fecha2)
  returning id into pid;

  for it in select * from jsonb_array_elements(p_items) loop
    u := (it ->> 'unidades')::int; pv := (it ->> 'precio_venta')::numeric;
    if u is null or u < 1 or u > 60 then raise exception 'Cantidad no válida'; end if;
    select * into pf from perfumes where id = (it ->> 'perfume_id')::bigint and visible_vendedoras and precio_consigna is not null;
    if not found then raise exception 'Ese perfume ya no está en el catálogo'; end if;
    if pv is null or pv < pf.precio_consigna then
      raise exception 'El precio de % no puede ser menor a $%', pf.nombre, pf.precio_consigna;
    end if;
    insert into pedidos_vendedora_items (pedido_id, perfume_id, unidades, precio_consigna, precio_venta)
    values (pid, pf.id, u, pf.precio_consigna, pv);
  end loop;
  return pid;
end $$;

-- Todos mis pedidos, con lo que gano, lo cobrado y lo que falta
create or replace function vend_mis_pedidos(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare vid bigint;
begin
  vid := vend_id(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'creado', r.creado, 'cliente', r.cliente, 'telefono', r.telefono, 'notas', r.notas,
      'plan', r.plan, 'fecha1', r.fecha1, 'fecha2', r.fecha2, 'estado', r.estado, 'nota_admin', r.nota_admin,
      'total_venta', r.total_venta, 'total_consigna', r.total_consigna, 'ganancia', r.ganancia_vendedora, 'ganada', r.ganancia_ganada,
      'cobrado', r.cobrado_cliente, 'falta', greatest(r.total_venta - r.cobrado_cliente, 0),
      'pagado_perfumeria', r.pagado_perfumeria, 'debe_perfumeria', r.debe_perfumeria,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('perfume', pf.nombre, 'unidades', i.unidades,
                  'consigna', i.precio_consigna, 'precio_venta', i.precio_venta) order by i.id), '[]'::jsonb)
                from pedidos_vendedora_items i join perfumes pf on pf.id = i.perfume_id where i.pedido_id = r.id),
      'cobros', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'fecha', c.fecha, 'monto', c.monto, 'quien', c.quien,
                  'nota', c.nota, 'borrable', c.creado > now() - interval '24 hours') order by c.fecha, c.id), '[]'::jsonb)
                from cobros_vendedora c where c.pedido_id = r.id)
    ) order by r.creado desc)
    from vendedora_pedidos_v r where r.vendedora_id = vid), '[]'::jsonb);
end $$;

-- Anotar un cobro del cliente (a quién, cuándo y cuánto)
create or replace function vend_registrar_cobro(p_token text, p_pedido_id bigint, p_fecha date, p_monto numeric, p_quien text, p_nota text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; r vendedora_pedidos_v%rowtype;
begin
  vid := vend_id(p_token);
  select * into r from vendedora_pedidos_v where id = p_pedido_id and vendedora_id = vid;
  if not found then raise exception 'No encuentro ese pedido'; end if;
  if r.estado not in ('aprobado','entregado') then raise exception 'Solo puedes anotar cobros cuando el pedido está aprobado'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'Escribe cuánto te pagaron'; end if;
  if char_length(trim(coalesce(p_quien, ''))) not between 2 and 60 then raise exception 'Escribe quién pagó'; end if;
  if p_fecha is null or p_fecha > (now() at time zone 'America/Caracas')::date + 1 then raise exception 'La fecha no es válida'; end if;
  if p_monto > (r.total_venta - r.cobrado_cliente) + 0.01 then
    raise exception 'Solo faltan $% por cobrar en este pedido', round(r.total_venta - r.cobrado_cliente, 2);
  end if;
  insert into cobros_vendedora (pedido_id, fecha, monto, quien, nota)
  values (p_pedido_id, p_fecha, p_monto, trim(p_quien), nullif(trim(coalesce(p_nota, '')), ''));
  return jsonb_build_object('ok', true);
end $$;

-- Borrar un cobro anotado por error (solo dentro de las primeras 24 horas)
create or replace function vend_borrar_cobro(p_token text, p_cobro_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; n int;
begin
  vid := vend_id(p_token);
  delete from cobros_vendedora c using pedidos_vendedora p
   where c.id = p_cobro_id and p.id = c.pedido_id and p.vendedora_id = vid and c.creado > now() - interval '24 hours';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Ya no se puede borrar ese cobro. Avísale a la perfumería.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Marcar que ya entregó el pedido al cliente
create or replace function vend_marcar_entregado(p_token text, p_pedido_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare vid bigint; n int;
begin
  vid := vend_id(p_token);
  update pedidos_vendedora set estado = 'entregado' where id = p_pedido_id and vendedora_id = vid and estado = 'aprobado';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Ese pedido no se puede marcar como entregado'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- 5. Funciones del control (solo socios) ----------
-- Crear o editar una vendedora. El PIN son 6 a 10 números; si lo dejas vacío al editar, no cambia.
create or replace function vend_guardar(p_id bigint, p_nombre text, p_usuario text, p_pin text, p_activa boolean)
returns bigint
language plpgsql security definer set search_path = public as $$
declare nid bigint; usr text := lower(trim(coalesce(p_usuario, ''))); sal text;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  if char_length(trim(coalesce(p_nombre, ''))) < 2 then raise exception 'Escribe el nombre'; end if;
  if usr !~ '^[a-z0-9_]{3,20}$' then raise exception 'El usuario son 3 a 20 letras minúsculas, números o _ (sin espacios)'; end if;
  if coalesce(p_pin, '') <> '' and p_pin !~ '^[0-9]{6,10}$' then raise exception 'El PIN son de 6 a 10 números'; end if;
  if p_id is null then
    if coalesce(p_pin, '') = '' then raise exception 'Pon un PIN de 6 a 10 números'; end if;
    insert into vendedoras (nombre, usuario, activa) values (trim(p_nombre), usr, coalesce(p_activa, true))
    returning id, salt into nid, sal;
    update vendedoras set pin_hash = vend_hash(sal || ':' || p_pin) where id = nid;
  else
    update vendedoras set nombre = trim(p_nombre), usuario = usr, activa = coalesce(p_activa, true),
                          intentos = 0, bloqueado_hasta = null where id = p_id returning id, salt into nid, sal;
    if nid is null then raise exception 'No encuentro esa vendedora'; end if;
    if coalesce(p_pin, '') <> '' then
      update vendedoras set pin_hash = vend_hash(sal || ':' || p_pin) where id = nid;
      delete from vendedora_sesiones where vendedora_id = nid;
    end if;
  end if;
  return nid;
end $$;

-- Aprobar: crea una venta por cada perfume, a precio de CONSIGNACIÓN (lo que ella te debe)
create or replace function vend_aprobar(p_id bigint) returns int
language plpgsql security invoker set search_path = public as $$
declare p pedidos_vendedora%rowtype; d vendedoras%rowtype; it record; tv numeric; vid bigint; ped text; n int := 0; hoy date;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  select * into p from pedidos_vendedora where id = p_id for update;
  if not found then raise exception 'No encuentro ese pedido'; end if;
  if p.estado <> 'pendiente' then raise exception 'Ese pedido ya fue revisado'; end if;
  select * into d from vendedoras where id = p.vendedora_id;
  select coalesce(euro, bcv) into tv from tasas order by fecha desc limit 1;
  if tv is null then raise exception 'Primero registra la tasa de hoy en la pestaña Tasas'; end if;
  hoy := (now() at time zone 'America/Caracas')::date;

  for it in select i.*, pf.nombre from pedidos_vendedora_items i join perfumes pf on pf.id = i.perfume_id where i.pedido_id = p.id order by i.id loop
    -- sale del pedido más antiguo con stock suficiente; si no hay, queda como venta anticipada (hay que comprarlo)
    select s.pedido_codigo into ped from stock_pedido_v s
     where s.perfume_id = it.perfume_id and s.restante >= it.unidades order by s.fecha, s.pedido_codigo limit 1;
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values (hoy, p.cliente || ' (vía ' || d.nombre || ')', d.nombre, it.perfume_id, ped, it.unidades, it.precio_consigna, 'divisa', tv, tv,
            coalesce(p.fecha2, p.fecha1),
            'Pedido de vendedora #' || p.id || ': ' || d.nombre || ' lo vende a $' || it.precio_venta || ' c/u y le quedan $' || (it.precio_venta - it.precio_consigna) || ' c/u')
    returning id into vid;
    update pedidos_vendedora_items set venta_id = vid where id = it.id;
    n := n + 1;
  end loop;
  update pedidos_vendedora set estado = 'aprobado', aprobado_por = coalesce(auth.jwt() ->> 'email', ''), aprobado_en = now() where id = p.id;
  return n;
end $$;

create or replace function vend_rechazar(p_id bigint, p_nota text) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  update pedidos_vendedora set estado = 'rechazado', nota_admin = nullif(trim(coalesce(p_nota, '')), ''),
         aprobado_por = coalesce(auth.jwt() ->> 'email', ''), aprobado_en = now()
   where id = p_id and estado = 'pendiente';
  if not found then raise exception 'Ese pedido ya fue revisado'; end if;
end $$;

-- La vendedora te paga: el dinero se aplica a sus ventas más antiguas primero
create or replace function vend_recibir_pago(p_vendedora_id bigint, p_monto numeric, p_cuenta text, p_fecha date) returns numeric
language plpgsql security invoker set search_path = public as $$
declare resto numeric := p_monto; fila record; abono numeric;
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  if p_monto is null or p_monto <= 0 then raise exception 'Escribe el monto'; end if;
  if p_cuenta not in ('binance','efectivo') then raise exception 'Elige efectivo o Binance'; end if;
  if p_monto > coalesce((select sum(v.pendiente_usd) from ventas_v v
        where v.id in (select i.venta_id from pedidos_vendedora_items i join pedidos_vendedora p on p.id = i.pedido_id
                        where p.vendedora_id = p_vendedora_id and i.venta_id is not null) and v.pendiente_usd > 0.005), 0) + 0.01 then
    raise exception 'Eso es más de lo que ella te debe';
  end if;
  for fila in select vv.id, vv.pendiente_usd from ventas_v vv
            where vv.id in (select i.venta_id from pedidos_vendedora_items i join pedidos_vendedora p on p.id = i.pedido_id
                             where p.vendedora_id = p_vendedora_id and i.venta_id is not null) and vv.pendiente_usd > 0.005
            order by vv.id loop
    exit when resto <= 0.004;
    abono := least(resto, fila.pendiente_usd);
    insert into cobros (venta_id, fecha, cuenta, monto) values (fila.id, coalesce(p_fecha, current_date), p_cuenta, round(abono, 2));
    resto := resto - abono;
  end loop;
  return p_monto - resto;
end $$;

-- ---------- 6. Permisos ----------
do $$
declare f text;
begin
  -- internas: nadie por la API
  foreach f in array array['stock_efectivo()', 'vend_id(text)', 'vend_hash(text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on function %s from anon, authenticated', f); end if;
  end loop;
  -- la tienda y las vendedoras (anon)
  foreach f in array array['tienda_catalogo()', 'vend_entrar(text,text)', 'vend_catalogo(text)',
      'vend_crear_pedido(text,text,text,text,text,date,date,jsonb)', 'vend_mis_pedidos(text)',
      'vend_registrar_cobro(text,bigint,date,numeric,text,text)', 'vend_borrar_cobro(text,bigint)', 'vend_marcar_entregado(text,bigint)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
  -- el control (solo usuarios con sesión)
  foreach f in array array['vend_guardar(bigint,text,text,text,boolean)', 'vend_aprobar(bigint)', 'vend_rechazar(bigint,text)',
      'vend_recibir_pago(bigint,numeric,text,date)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on function %s from anon', f);
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

-- >>>>>>>>>> migracion_v10.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v10 · Marca, género, notas olfativas, tips de venta y ficha del perfume
-- Ejecutar DESPUÉS de migracion_v9.sql. Es segura de repetir.
--  - perfumes: marca, genero (hombre / mujer / unisex), notas (olfativas) y tips_venta (solo para vendedoras)
--  - La marca y el género se llenan una sola vez leyendo el nombre; lo que ya hayas escrito NO se pisa.
--  - tienda_catalogo() y vend_catalogo() devuelven los campos nuevos (la tienda nunca recibe tips_venta).
--  - vend_info(): número de WhatsApp de la perfumería para el aviso de pedidos de las vendedoras.
-- =====================================================================

alter table perfumes add column if not exists marca text;
alter table perfumes add column if not exists genero text;
alter table perfumes add column if not exists notas text;
alter table perfumes add column if not exists tips_venta text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'perfumes_genero_ck') then
    alter table perfumes add constraint perfumes_genero_ck check (genero is null or genero in ('hombre','mujer','unisex'));
  end if;
end $$;

-- ---------- Llenado inicial de marca (solo donde está vacía) ----------
-- Se busca la primera marca de la lista que aparezca dentro del nombre. Revísalas en Catálogo.
with marcas(patron, marca) as (values
  ('carolina herrera', 'Carolina Herrera'), ('212 vip', 'Carolina Herrera'), ('good girl', 'Carolina Herrera'),
  ('la bomba', 'Carolina Herrera'), ('bad boy', 'Carolina Herrera'), ('la vie est belle', 'Lancôme'), ('lancome', 'Lancôme'),
  ('paco rabanne', 'Paco Rabanne'), ('invictus', 'Paco Rabanne'), ('one million', 'Paco Rabanne'),
  ('mont ?blanc', 'Montblanc'), ('moschino', 'Moschino'), ('bharara', 'Bharara'),
  ('afnan', 'Afnan'), ('9 ?pm', 'Afnan'), ('9 ?am', 'Afnan'), ('lattafa', 'Lattafa'), ('yara', 'Lattafa'), ('asad', 'Lattafa'),
  ('khamrah', 'Lattafa'), ('mayar', 'Lattafa'), ('art of universe', 'Lattafa'), ('armaf', 'Armaf'), ('club de nuit', 'Armaf'),
  ('odyssey', 'Armaf'), ('orientica', 'Orientica'), ('rasasi', 'Rasasi'), ('swiss army', 'Swiss Army'),
  ('ariana grande', 'Ariana Grande'), ('thank u next', 'Ariana Grande'), ('katy perry', 'Katy Perry'), ('meow', 'Katy Perry'),
  ('fantasy', 'Britney Spears'), ('paris hilton', 'Paris Hilton'), ('lacoste', 'Lacoste'), ('perry ellis', 'Perry Ellis'),
  ('giorgio armani', 'Giorgio Armani'), ('acqua di gio', 'Giorgio Armani'), ('valentino', 'Valentino'),
  ('dolce', 'Dolce & Gabbana'), ('versace', 'Versace'), ('jean paul', 'Jean Paul Gaultier'), ('yves saint', 'Yves Saint Laurent'),
  ('calvin klein', 'Calvin Klein'), ('hugo boss', 'Hugo Boss'), ('azzaro', 'Azzaro'), ('dior', 'Dior'), ('chanel', 'Chanel'),
  ('santal 33', 'Le Labo'), ('bestia negra', 'Armaf'), ('victoria', 'Victoria''s Secret'), ('victorinox', 'Victorinox')
)
update perfumes pf set marca = (select m.marca from marcas m where lower(pf.nombre) ~ m.patron limit 1)
where coalesce(trim(pf.marca), '') = '';

-- ---------- Llenado inicial de género (solo donde está vacío) ----------
update perfumes set genero = case
  when lower(nombre) ~ '(set de regalo)' then null
  when lower(nombre) ~ '(unisex|khamrah|santal|art of universe|amber rouge)' then 'unisex'
  when lower(nombre) ~ '(\mmen\M|\mmen$|hombre|invictus|one million|bad boy|\m212 vip( black)?$|odyssey|club de nuit|bestia negra|acqua di gio|starwalker|legend|viking|asad|toy boy|perry ellis 360|swiss army|\m360\M|lacoste white|tyrant|mega men|lujo premium men)' then 'hombre'
  when lower(nombre) ~ '(\mfem\M|femme|mujer|good girl|la vie est belle|la bomba|candy|yara|fantasy|meow|cloud|mod blush|mod vainilla|thank u next|donna|rose|mayar|can can|beach party|night out|9 ?pm|9 ?am)' then 'mujer'
  else null end
where genero is null;

-- ---------- La tienda: ahora con marca, género y notas (nunca tips de venta, consigna ni costo) ----------
drop function if exists tienda_catalogo();
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text, marca text, genero text, notas text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion,
         nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), '')
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.nombre;
$$;

-- ---------- Las vendedoras: ficha completa (descripción, notas y tips para vender). Nunca costo ni mayor ----------
drop function if exists vend_catalogo(text);
create or replace function vend_catalogo(p_token text)
returns table (id bigint, nombre text, descripcion text, foto_url text, foto2_url text,
               precio_consigna numeric, precio_sugerido numeric, disponible boolean,
               marca text, genero text, notas text, tips_venta text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return query
    select pf.id, pf.nombre, pf.descripcion, pf.foto_url, pf.foto2_url, pf.precio_consigna, pf.precio_detal, s.stock > 0,
           nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), ''), nullif(trim(pf.tips_venta), '')
    from perfumes pf join stock_efectivo() s on s.perfume_id = pf.id
    where pf.visible_vendedoras and pf.precio_consigna is not null
    order by pf.nombre;
end $$;

-- ---------- Datos de contacto para el aviso por WhatsApp (solo con sesión de vendedora) ----------
create or replace function vend_info(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return (select jsonb_build_object('nombre', c.nombre, 'whatsapp', c.whatsapp) from tienda_config c where c.id = 1);
end $$;

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'vend_catalogo(text)', 'vend_info(text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
end $$;

-- >>>>>>>>>> migracion_v11.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v11 · Pedido 3 corregido, orden manual de perfumes y conversión Bs → divisa (merma)
-- Ejecutar DESPUÉS de migracion_v10.sql. Es segura de repetir (la corrección del pedido 3 se aplica una sola vez).
--
--  1. Pedido 3: se reemplaza su lista de compras por la lista real recibida (50 perfumes, $505) y los
--     17 decants porta perfumes ($21, no se venden) se anotan como gasto del pedido. Se renombran los
--     perfumes que llegaron con otro nombre y se ocultan los que no llegaron (si no tienen compras ni ventas).
--  2. perfumes.orden: orden manual de la tienda (se arrastra en Inventario). Marcas parecidas quedan juntas.
--  3. conversiones: registra cuando compras divisa con Bs. Calcula la merma (lo que se pierde en el cambio)
--     y mueve la caja: sale Bs, entra divisa.
-- =====================================================================

-- ---------- 1. Orden manual de los perfumes ----------
alter table perfumes add column if not exists orden int;

create or replace function perfumes_ordenar(p_ids bigint[]) returns void
language plpgsql security invoker set search_path = public as $$
begin
  if not es_socio() then raise exception 'No autorizado'; end if;
  update perfumes set orden = x.n
  from unnest(p_ids) with ordinality as x(id, n)
  where perfumes.id = x.id;
end $$;

-- La tienda y las vendedoras ven los perfumes en el orden manual
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text, marca text, genero text, notas text)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion,
         nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), '')
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.orden nulls last, pf.nombre;
$$;

create or replace function vend_catalogo(p_token text)
returns table (id bigint, nombre text, descripcion text, foto_url text, foto2_url text,
               precio_consigna numeric, precio_sugerido numeric, disponible boolean,
               marca text, genero text, notas text, tips_venta text)
language plpgsql stable security definer set search_path = public as $$
begin
  perform vend_id(p_token);
  return query
    select pf.id, pf.nombre, pf.descripcion, pf.foto_url, pf.foto2_url, pf.precio_consigna, pf.precio_detal, s.stock > 0,
           nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), ''), nullif(trim(pf.tips_venta), '')
    from perfumes pf join stock_efectivo() s on s.perfume_id = pf.id
    where pf.visible_vendedoras and pf.precio_consigna is not null
    order by pf.orden nulls last, pf.nombre;
end $$;

-- ---------- 2. Conversión de Bs a divisa y merma ----------
create table if not exists conversiones (
  id bigint generated always as identity primary key,
  fecha date not null default current_date,
  bs numeric not null check (bs > 0),                          -- bolívares que se entregaron
  divisa numeric not null check (divisa > 0),                  -- dólares que se recibieron
  cuenta text not null default 'binance' check (cuenta in ('binance','efectivo')),   -- dónde entró la divisa
  tasa_bcv numeric not null check (tasa_bcv > 0),              -- BCV $ con la que se cobraron esos Bs (interna)
  nota text,
  registrado_por text default coalesce(auth.jwt() ->> 'email', '')
);
alter table conversiones enable row level security;
drop policy if exists solo_socios on conversiones;
create policy solo_socios on conversiones for all using (es_socio()) with check (es_socio());

-- Merma = lo que esos Bs valían a la tasa BCV $ del cobro, menos la divisa que de verdad se recibió
create or replace view conversiones_v with (security_invoker = true) as
select c.*,
       round(c.bs / c.divisa, 4) as tasa_real,
       round(c.bs / c.tasa_bcv, 2) as esperado_usd,
       round(c.bs / c.tasa_bcv - c.divisa, 2) as merma_usd,
       round((c.bs / c.tasa_bcv - c.divisa) / (c.bs / c.tasa_bcv), 4) as merma_pct
from conversiones c;

-- La caja: la conversión saca los Bs y mete la divisa
create or replace view caja_v with (security_invoker = true) as
select cuenta, sum(monto) as saldo from (
  select cuenta, monto from cobros
  union all select cuenta, monto from movimientos
  union all select cuenta, -monto from gastos where cuenta is not null
  union all select 'bs', -bs from conversiones
  union all select cuenta, divisa from conversiones
) x group by cuenta;

-- ---------- 3. Pedido 3: corrección ----------
create or replace function v11_renombrar(p_viejo text, p_nuevo text) returns void
language plpgsql set search_path = public as $$
begin
  if exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_viejo)))
     and not exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_nuevo))) then
    update perfumes set nombre = p_nuevo where lower(trim(nombre)) = lower(trim(p_viejo));
    update agenda_lineas set nombre = p_nuevo where lower(trim(nombre)) = lower(trim(p_viejo));
  end if;
end $$;

create or replace function v11_perfume(p_nombre text, p_marca text, p_genero text) returns void
language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from perfumes where lower(trim(nombre)) = lower(trim(p_nombre))) then
    insert into perfumes (nombre, marca, genero) values (p_nombre, p_marca, p_genero);
  end if;
end $$;

do $$
declare
  r record; f record; faltan text := ''; ventas_movidas text := ''; saldo int; v record; pid bigint;
begin
  if exists (select 1 from cargas_hechas where clave = 'p3_correccion_v11') then
    raise notice 'La corrección del pedido 3 ya estaba aplicada. No se repite.';
    return;
  end if;
  if not exists (select 1 from pedidos where codigo = 'P-003') then
    raise notice 'No existe el pedido P-003: se omite la corrección.';
    return;
  end if;

  -- Nombres que llegaron distintos
  perform v11_renombrar('Lattafa Yara Fem', 'Lattafa Yara Clásico');
  perform v11_renombrar('Lattafa Mayar Lujo Premium', 'Lattafa Mayar Natural Intense');
  perform v11_renombrar('Victorinox', 'Victorinox Swiss Army Classic');
  perform v11_renombrar('Perry Ellis 360', 'Perry Ellis 360 for Men');
  perform v11_renombrar('Perry Ellis Coral', 'Perry Ellis 360 Coral');
  -- La Vie Est Belle: se renombra sin importar cómo esté escrita hoy en tu catálogo
  if not exists (select 1 from perfumes where lower(trim(nombre)) = lower('Lancôme La Vie Est Belle'))
     and exists (select 1 from perfumes where nombre ~* 'la vie est belle') then
    update agenda_lineas set nombre = 'Lancôme La Vie Est Belle' where nombre ~* 'la vie est belle';
    update perfumes set nombre = 'Lancôme La Vie Est Belle'
     where id = (select id from perfumes where nombre ~* 'la vie est belle' order by id limit 1);
  end if;
  perform v11_renombrar('Bharara Viking', 'Bharara Viking Kashmir Lujo');
  update perfumes set marca = 'Lancôme' where lower(nombre) = lower('Lancôme La Vie Est Belle');

  -- Perfumes nuevos que llegaron
  perform v11_perfume('Paco Rabanne One Million Lucky', 'Paco Rabanne', 'hombre');
  perform v11_perfume('Valentino Donna Fem', 'Valentino', 'mujer');
  perform v11_perfume('Carolina Herrera 212 VIP Rose Fem', 'Carolina Herrera', 'mujer');
  perform v11_perfume('Lattafa Yara Tous Fem', 'Lattafa', 'mujer');
  perform v11_perfume('Afnan 9am Dive Unisex', 'Afnan', 'unisex');

  -- Lista real del pedido 3 (50 perfumes · $505). El splash: $26 por los 10 = $2,60 c/u.
  create temp table _p3 (nombre text, unid int, costo numeric) on commit drop;
  insert into _p3 values
    ('Ariana Grande Cloud', 2, 11.5), ('Ariana Grande Thank U Next', 2, 11.5), ('Bestia Negra', 2, 12),
    ('Bharara Rose Fem Lujo Premium', 1, 16), ('Carolina Herrera 212 VIP Black', 1, 11), ('Carolina Herrera 212 VIP Fem', 1, 11),
    ('Carolina Herrera Good Girl Fem', 1, 11), ('Lancôme La Vie Est Belle', 1, 10), ('Lattafa Art of Universe', 1, 19),
    ('Lattafa Mayar Natural Intense', 1, 16), ('Lattafa Yara Clásico', 3, 12), ('Lattafa Yara Candy Fem', 3, 12),
    ('Paco Rabanne Invictus Intense', 1, 10), ('Invictus Parfum Paco Rabanne', 1, 11), ('Paco Rabanne One Million Lucky', 1, 11),
    ('Fantasy', 2, 10), ('Armaf Odyssey Mandarin Sky Elixir', 2, 12.5), ('Ariana Grande Mod Blush', 1, 11),
    ('Ariana Grande Mod Vainilla', 1, 11), ('Victorinox Swiss Army Classic', 2, 10.5), ('9 PM Night Out', 2, 13),
    ('Perry Ellis 360 Coral', 1, 10), ('Perry Ellis 360 for Men', 1, 10), ('Armaf Odyssey Tyrant Men', 1, 13),
    ('Valentino Donna Fem', 1, 12), ('Victoria Secret Splash 250ml (variados)', 10, 2.6), ('Carolina Herrera 212 VIP Rose Fem', 1, 11),
    ('Bharara Viking Kashmir Lujo', 1, 18), ('Lattafa Yara Tous Fem', 1, 12), ('Afnan 9am Dive Unisex', 1, 11);

  for r in select t.nombre from _p3 t where not exists (select 1 from perfumes pf where lower(trim(pf.nombre)) = lower(trim(t.nombre))) loop
    faltan := faltan || E'\n  • ' || r.nombre;
  end loop;
  if faltan <> '' then
    raise exception 'No se encontraron estos perfumes y no se aplicó nada:%', faltan;
  end if;

  -- Reemplazar las compras del pedido 3
  delete from compras where pedido_codigo = 'P-003';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
  select 'P-003', pf.id, t.unid, t.costo from _p3 t join perfumes pf on lower(trim(pf.nombre)) = lower(trim(t.nombre));

  -- Las ventas atadas al pedido 3 de perfumes que ya no llegaron (o que llegaron menos) pasan a "anticipadas"
  for f in
    select v2.perfume_id, sum(v2.unidades) vendidas,
           coalesce((select sum(c.unidades) from compras c where c.pedido_codigo = 'P-003' and c.perfume_id = v2.perfume_id), 0) comprados
    from ventas v2 where v2.pedido_codigo = 'P-003' group by v2.perfume_id
  loop
    saldo := f.vendidas - f.comprados;
    if saldo > 0 then
      for v in select id, unidades, cliente from ventas where pedido_codigo = 'P-003' and perfume_id = f.perfume_id order by id desc loop
        exit when saldo <= 0;
        update ventas set pedido_codigo = null where id = v.id;
        saldo := saldo - v.unidades;
        ventas_movidas := ventas_movidas || E'\n  • venta #' || v.id || ' de ' || v.cliente || ' (' || (select nombre from perfumes where id = f.perfume_id) || ')';
      end loop;
    end if;
  end loop;
  if ventas_movidas <> '' then
    raise notice 'Estas ventas ya no tienen stock en el pedido 3 y quedaron como anticipadas (se ven en Por comprar):%', ventas_movidas;
  end if;

  -- Los perfumes que no llegaron y no tienen compras ni ventas dejan de verse en la tienda y para las vendedoras
  update perfumes pf set visible_tienda = false, visible_vendedoras = false
  where lower(trim(pf.nombre)) in ('lattafa asad men', 'santal 33', 'valentino born in roma intense', 'moschino toy boy', 'one million paco rabanne')
    and not exists (select 1 from compras c where c.perfume_id = pf.id)
    and not exists (select 1 from ventas v3 where v3.perfume_id = pf.id);

  -- Los 17 decants porta perfumes: no se venden, son un gasto del pedido
  if not exists (select 1 from gastos where concepto like '17 decants porta perfumes%') then
    insert into gastos (fecha, categoria, concepto, monto, pedido_codigo)
    values ('2026-10-19', 'empaque', '17 decants porta perfumes para muestras (no se venden)', 21, 'P-003');
  end if;

  insert into cargas_hechas (clave) values ('p3_correccion_v11');
end $$;

drop function if exists v11_renombrar(text, text);
drop function if exists v11_perfume(text, text, text);

-- ---------- 4. Orden inicial: marcas parecidas juntas (solo a los que aún no tienen orden) ----------
update perfumes pf set orden = x.n + coalesce((select max(orden) from perfumes), 0)
from (select id, row_number() over (order by (nullif(trim(marca), '') is null), lower(trim(marca)), lower(nombre)) n
      from perfumes where orden is null) x
where pf.id = x.id;

-- ---------- Permisos ----------
do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'vend_catalogo(text)'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
  execute 'revoke all on function perfumes_ordenar(bigint[]) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function perfumes_ordenar(bigint[]) from anon';
    execute 'grant execute on function perfumes_ordenar(bigint[]) to authenticated';
  end if;
end $$;

-- >>>>>>>>>> migracion_v12.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v12 · Cierre del lote 3 con lo que quedó en existencia (30/10)
-- Ejecutar DESPUÉS de migracion_v11.sql. Se aplica UNA sola vez aunque la repitas.
-- ANTES: en "Tasa del día" guarda hoy las 3 tasas: BCV Euro, Binance y BCV $ (dólar).
--  - Cambia 3 ventas agendadas por el perfume que de verdad se entregó (Carola, Almari, Rosangela).
--  - Ajusta las fechas de pago de Jhoany Guitian (Yara Candy).
--  - Registra las ventas nuevas que faltaban y el gasto de $20 (comida) pagado en efectivo.
-- NO toca la caja: el conteo real se ajusta desde la pestaña Caja ("Conteo real").
-- =====================================================================

create or replace function v12_bcv(p_fecha date) returns numeric
language sql stable as $f$
  select coalesce(
    (select bcv from tasas where fecha <= p_fecha and bcv > 0 order by fecha desc limit 1),
    (select bcv from tasas where bcv > 0 order by fecha desc limit 1))
$f$;

create or replace function v12_perf(p_nombre text) returns bigint
language plpgsql stable as $f$
declare pid bigint;
begin
  select id into pid from perfumes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if pid is null then raise exception 'No encuentro el perfume "%" en tu catálogo. Avísame cómo se llama.', p_nombre; end if;
  return pid;
end $f$;

do $$
declare
  eu numeric; tb numeric; tbcv numeric; v_id bigint; r record; n int := 0;
begin
  if exists (select 1 from cargas_hechas where clave = 'v12_lote3_final') then
    raise notice 'El cierre del lote 3 ya estaba aplicado. No se repite.'; return;
  end if;
  select euro, binance into eu, tb from tasas order by fecha desc limit 1;
  tbcv := v12_bcv(current_date);
  if coalesce(eu, 0) <= 0 or coalesce(tb, 0) <= 0 or coalesce(tbcv, 0) <= 0 then
    raise exception 'Primero guarda en "Tasa del día" las 3 tasas de hoy (BCV Euro, Binance y BCV $) y vuelve a ejecutar esto.';
  end if;

  -- ---------- 1. Ventas agendadas que cambiaron de perfume ----------
  -- Carola: la Yara Moi (que no llegó) se cambió por la Yara Tous que estaba disponible
  update ventas set perfume_id = v12_perf('Lattafa Yara Tous Fem'), pedido_codigo = 'P-003',
         nota = 'Con Mandarin Sky: total $60. Cambió la Yara Moi agendada por la Yara Tous. Pagará 50% el 30/10 y 50% el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Carola Carvajal' and pf.nombre = 'Lattafa Yara Moi' order by v.id limit 1);

  -- Almari: no se llevó la Yara; la cambió por la Bharara Rose Lujo Premium ($45 BCV $)
  update ventas set perfume_id = v12_perf('Bharara Rose Fem Lujo Premium'), pedido_codigo = 'P-003', precio_unit = 45,
         base = 'bcv', tasa_bcv = v12_bcv(fecha), vendedor = 'Rosanny', vence = '2026-11-15',
         nota = 'Cambió la Yara por la Bharara Rose. $45 BCV$. Paga la mitad el 31/10 y la otra mitad el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Almari' and pf.nombre = 'Lattafa Yara Clásico' order by v.id limit 1);

  -- Rosangela Cequea: se llevó el Valentino Donna Fem en vez del que tenía agendado (sus cobros se conservan)
  update ventas set perfume_id = v12_perf('Valentino Donna Fem'), pedido_codigo = 'P-003', vendedor = 'Rosanny',
         nota = trim(coalesce(nota || ' · ', '') || 'Se llevó el Donna Fem en vez del agendado')
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Rosangela Cequea' and pf.nombre = 'Valentino Donna Intense' order by v.id limit 1);

  -- Jhoany Guitian (Yara Candy, vendida por Rosanny): $35 BCV $, paga 31/10 y 15/11
  update ventas set cliente = 'Jhoany Guitian', base = 'bcv', tasa_bcv = v12_bcv(fecha), vence = '2026-11-15',
         nota = 'Yara Candy. $35 BCV$. Paga el 31/10 y el 15/11'
   where id in (select v.id from ventas v join perfumes pf on pf.id = v.perfume_id
                where v.cliente = 'Jhoanny' and pf.nombre = 'Lattafa Yara Candy Fem' order by v.id limit 1);

  -- ---------- 2. Ventas nuevas (fecha 30/10) ----------
  -- (cliente, vendedor, perfume, precio, base, tasa_bcv, vence, nota)
  drop table if exists pg_temp._v12;
  create temp table _v12 (cliente text, vendedor text, perfume text, precio numeric, base text, tbcv numeric,
                          vence date, nota text) on commit drop;
  insert into _v12 values
   ('Jefren', 'Jose Montilva', '9 PM Night Out', 30, 'bcv', 888, null, '$30 BCV$ a 888 Bs por dólar. Pagó completo en Bs'),
   ('Hijo del Carpintero', 'Jose Montilva', 'Afnan 9am Dive Unisex', 35, 'bcv', tbcv, '2026-11-15', '$35 BCV$. Paga el 31/10 y el 15/11'),
   ('Juan Perez', 'Juan', 'Armaf Odyssey Mandarin Sky Elixir', 35, 'divisa', eu, '2026-11-15', 'Paga la mitad el 31/10 y la otra mitad el 15/11'),
   ('Frank Transportista', 'Wuilesmar', 'Bestia Negra', 30, 'bcv', eu, '2026-11-15', '$30 BCV Euro. Primera mitad el 30/10 (aún por cobrar) y la otra el 15/11'),
   ('Carpintero', 'Jose Montilva', 'Bharara Viking Kashmir Lujo', 45, 'bcv', tbcv, '2026-11-15', '$45 BCV$. Paga la mitad el 31/10 y la otra mitad el 15/11'),
   ('Cliente de Gardimar', 'Wuilesmar', 'Carolina Herrera 212 VIP Rose Fem', 25, 'bcv', eu, null, '$25 BCV Euro. Aún por cobrar'),
   ('Andreina (esposa de Ismael)', 'Wuilesmar', 'Lattafa Yara Clásico', 25, 'divisa', eu, '2026-11-15', 'Paga la primera parte el 31/10 y la segunda el 15/11'),
   ('Jessica', 'George', 'Lattafa Yara Candy Fem', 30, 'bcv', tbcv, '2026-11-17', 'Yara Candy. $30 BCV$. Paga el 2/11 y el 17/11');

  for r in select * from _v12 loop
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values ('2026-10-30', r.cliente, r.vendedor, v12_perf(r.perfume), 'P-003', 1, r.precio, r.base, r.tbcv, tb, r.vence, r.nota)
    returning id into v_id;
    n := n + 1;
    if r.cliente = 'Jefren' then   -- pagó completo en bolívares: 30 × 888 = 26.640 Bs
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-30', 'bs', 30 * 888);
    end if;
  end loop;

  -- ---------- 3. Gasto de comida ($20 en efectivo) ----------
  insert into gastos (fecha, categoria, concepto, monto, cuenta, pagado_por)
  values ('2026-10-30', 'otro', 'Arroz chino para comer', 20, 'efectivo', 'Juan');

  insert into cargas_hechas (clave) values ('v12_lote3_final');
  raise notice 'Cierre del lote 3 aplicado: 4 ventas ajustadas, % ventas nuevas y 1 gasto.', n;
end $$;

drop function if exists v12_bcv(date);
drop function if exists v12_perf(text);

-- >>>>>>>>>> cobros_30oct.sql <<<<<<<<<<
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

-- >>>>>>>>>> migracion_v13.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v13 · Lote 4 (P-004), sus ventas y dos cobros (1/11)
-- Ejecutar DESPUÉS de migracion_v12.sql. Se aplica UNA sola vez aunque la repitas.
-- Antes: en "Tasa del día" debe estar guardada la tasa de hoy (BCV Euro y Binance).
--  1. Cobros: Jesus Teran abona $20 (efectivo) y Doris Teran paga $35 (efectivo).
--  2. Pedido P-004: 26 perfumes, $352, aportado por los 3 socios en partes iguales.
--  3. Ventas del lote 4 y sus pagos.
--  4. Agenda A-001: se quitan los perfumes que ya llegaron en este lote.
-- NO mueve la caja: el lote se financió con aportes de los socios.
-- =====================================================================

create or replace function v13_perf(p_nombre text, p_marca text default null, p_genero text default null) returns bigint
language plpgsql as $f$
declare pid bigint;
begin
  select id into pid from perfumes where lower(trim(nombre)) = lower(trim(p_nombre)) limit 1;
  if pid is null then
    insert into perfumes (nombre, marca, genero, orden)
    values (p_nombre, p_marca, p_genero, coalesce((select max(orden) from perfumes), 0) + 1) returning id into pid;
  end if;
  return pid;
end $f$;

do $$
declare
  tv numeric; tb numeric; v_id bigint; n int := 0; r record; hay int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v13_lote4') then
    raise notice 'El lote 4 ya estaba cargado. No se repite.'; return;
  end if;
  select euro, binance into tv, tb from tasas order by fecha desc limit 1;
  if coalesce(tv, 0) <= 0 or coalesce(tb, 0) <= 0 then
    raise exception 'Primero guarda en "Tasa del día" la tasa de hoy (BCV Euro y Binance) y vuelve a ejecutar esto.';
  end if;

  -- ---------- 1. Cobros ----------
  select v.id into v_id from ventas_v v where lower(v.cliente) like 'jesus teran%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Jesus Teran.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', 'efectivo', 20);

  select v.id into v_id from ventas_v v where lower(v.cliente) like 'doris teran%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Doris Teran.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', 'efectivo', 35);

  -- ---------- 2. Pedido P-004 ----------
  insert into pedidos (codigo, fecha, proveedor, envio) values ('P-004', '2026-11-01', null, 0) on conflict do nothing;
  insert into pedido_socios (pedido_codigo, socio, aporte, participacion) values
    ('P-004', 'Juan', 117.33, 1.0/3), ('P-004', 'George', 117.33, 1.0/3), ('P-004', 'Rosanny', 117.34, 1.0/3)
  on conflict do nothing;

  drop table if exists pg_temp._p4;
  create temp table _p4 (pid bigint, unid int, costo numeric) on commit drop;
  insert into _p4 values
   (v13_perf('Bestia Negra'), 1, 12),                                                            -- Armaf Club de Nuit
   (v13_perf('Mont Blanc Legend Spirit'), 1, 10),
   (v13_perf('Lattafa Yara Moi'), 1, 12),
   (v13_perf('Victoria Secret Splash 250ml (variados)'), 1, 3),                                  -- Vainilla Lace
   (v13_perf('Bharara Rose Fem Lujo Premium'), 1, 16),
   (v13_perf('Lattafa Khamrah Karaz Unisex Lujo Premium'), 1, 16),
   (v13_perf('Carolina Herrera Good Girl Fem'), 1, 11),
   (v13_perf('9 PM Night Out'), 2, 13),
   (v13_perf('Armaf Odyssey Mandarin Sky', 'Armaf', 'hombre'), 1, 13),
   (v13_perf('Armaf Odyssey Mandarin Sky Elixir'), 1, 13),
   (v13_perf('Armaf Yum Yum Lujo Premium', 'Armaf', 'mujer'), 1, 19),
   (v13_perf('Armaf Infinity Gold Fem Lujo Premium', 'Armaf', 'mujer'), 1, 19),
   (v13_perf('Ariana Grande Mod Blush'), 1, 11),
   (v13_perf('Jean Paul Gaultier Scandal Intense Fem', 'Jean Paul Gaultier', 'mujer'), 1, 11),
   (v13_perf('Lattafa Emeer Unisex Lujo Premium', 'Lattafa', 'unisex'), 1, 19),
   (v13_perf('Bharara Kinh Soleil Lujo Premium', 'Bharara', null), 1, 17),
   (v13_perf('Xerjoff Erba Pure Lujo Premium', 'Xerjoff', 'unisex'), 1, 17),
   (v13_perf('Valentino Uomo Born in Roma', 'Valentino', 'hombre'), 2, 12),
   (v13_perf('Lattafa Noble Blush Lujo Premium', 'Lattafa', 'mujer'), 1, 14),
   (v13_perf('Armaf Odyssey Mandarine Sky Vintage Edition', 'Armaf', 'hombre'), 1, 13),
   (v13_perf('Armaf Odyssey Pink Pop Fem', 'Armaf', 'mujer'), 1, 13),
   (v13_perf('Armaf Odyssey Candee', 'Armaf', 'mujer'), 1, 13),
   (v13_perf('Al Haramain Amber Oud Gold Edition', 'Al Haramain', 'unisex'), 1, 15),
   (v13_perf('Lattafa Ajwad Lujo Premium', 'Lattafa', 'unisex'), 1, 15);
  delete from compras where pedido_codigo = 'P-004';
  insert into compras (pedido_codigo, perfume_id, unidades, costo_unitario)
  select 'P-004', pid, unid, costo from _p4;

  -- ---------- 3. Ventas del lote 4 (fecha 1/11) ----------
  drop table if exists pg_temp._v13;
  create temp table _v13 (cliente text, vendedor text, perfume text, precio numeric, base text, vence date, nota text,
                          cobro numeric, cuenta text, pedido text) on commit drop;
  insert into _v13 values
   ('Felix Aqua Vic', 'Juan', 'Bharara Kinh Soleil Lujo Premium', 40, 'divisa', '2026-11-15', 'Pagó la mitad ($20) y debe $20 para el 15/11', 20, 'efectivo', 'P-004'),
   ('Ariana Marquez', 'Juan', 'Carolina Herrera Good Girl Fem', 35, 'divisa', '2026-11-30', 'Paga la mitad el 15/11 y la otra mitad el 30/11', 0, null, 'P-004'),
   ('Adriana Aqua Vic', 'Juan', 'Armaf Odyssey Pink Pop Fem', 35, 'divisa', null, 'Pago completo por Binance', 35, 'binance', 'P-004'),
   ('Rosanna Aqua Vic', 'George', 'Ariana Grande Mod Blush', 35, 'bcv', '2026-11-15', '$35 BCV Euro. Paga la mitad el 2/11 y la otra mitad el 15/11', 0, null, 'P-004'),
   ('Jema de La Hoz', 'George', 'Armaf Odyssey Mandarin Sky', 30, 'divisa', '2026-11-15', 'Con One Million Lucky: total $60. Paga el 15/11', 0, null, 'P-004'),
   ('Jema de La Hoz', 'George', 'Paco Rabanne One Million Lucky', 30, 'divisa', '2026-11-15', 'Con Mandarin Sky: total $60. Paga el 15/11', 0, null, 'P-003');
  for r in select * from _v13 loop
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence, nota)
    values ('2026-11-01', r.cliente, r.vendedor, v13_perf(r.perfume), r.pedido, 1, r.precio, r.base, tv, tb, r.vence, r.nota)
    returning id into v_id;
    n := n + 1;
    if r.cobro > 0 then
      insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-11-01', r.cuenta, r.cobro);
    end if;
  end loop;

  -- La reserva de Mauricio Garcez (Mont Blanc Legend Spirit) ya tiene su perfume: pasa al pedido P-004
  update ventas set pedido_codigo = 'P-004'
   where pedido_codigo is null and cliente = 'Mauricio Garcez' and perfume_id = v13_perf('Mont Blanc Legend Spirit');

  -- ---------- 4. Agenda A-001: quitar lo que ya llegó ----------
  delete from agenda_lineas
   where codigo = 'A-001' and unidades <= 1
     and nombre in ('Armaf Odyssey Mandarin Sky Elixir', 'Bestia Negra', '9 PM Night Out', 'Mont Blanc Legend Spirit', 'Victoria Secret Splash 250ml (variados)');
  update agenda_lineas set unidades = unidades - 1
   where codigo = 'A-001' and unidades > 1
     and nombre in ('Armaf Odyssey Mandarin Sky Elixir', 'Bestia Negra', '9 PM Night Out', 'Mont Blanc Legend Spirit', 'Victoria Secret Splash 250ml (variados)');

  insert into cargas_hechas (clave) values ('v13_lote4');
  raise notice 'Lote 4 cargado: % perfumes, % ventas nuevas, 2 cobros.', (select sum(unid) from _p4), n;
end $$;

drop function if exists v13_perf(text, text, text);

-- >>>>>>>>>> migracion_v14.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v14 · Todo en dólares, tasa BCV en cada cobro en Bs, merma por pedido y datos del 1/11
-- Ejecutar DESPUÉS de migracion_v13.sql. Las partes de CARGA se aplican una sola vez.
--
--  1. cobros.tasa_bcv: la tasa BCV a la que pagó el cliente en Bs. Los cobros viejos se completan solos.
--  2. Las ventas valen su monto en dólares ($35 son $35). Un cobro en Bs vale Bs ÷ tasa BCV pagada.
--  3. merma_cobros_v / merma_pedido_v: lo que se pierde por la brecha en cada cobro en Bs y por pedido
--     (BCV pagada contra Binance del día del cobro).
--  4. Datos: pago del lote 4 desde la caja ($345 efectivo), taxi $11, cobro de Eduin Torres,
--     segunda venta del Thank U Next y corrección del splash (eran 9, no 10, en el pedido 3).
-- =====================================================================

-- ---------- 1. Tasa BCV en cada cobro ----------
alter table cobros add column if not exists tasa_bcv numeric;
update cobros co set tasa_bcv = coalesce(co.tasa_binance, v.tasa_bcv)
from ventas v where v.id = co.venta_id and co.cuenta = 'bs' and co.tasa_bcv is null;

-- ---------- 2. Ventas en dólares nominales ----------
create or replace view ventas_v with (security_invoker = true) as
select x.*,
       x.valor_usd - x.cobrado_usd as pendiente_usd,
       x.costo_unit * x.unidades as costo_total,
       case when x.costo_unit is null then null else x.valor_usd - x.costo_unit * x.unidades end as ganancia
from (
  select v.*, pf.sku, pf.nombre,
         v.unidades * v.precio_unit as total_pactado,
         v.unidades * v.precio_unit as valor_usd,
         coalesce((select sum(case when co.cuenta = 'bs' then co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) else co.monto end)
                   from cobros co where co.venta_id = v.id), 0) as cobrado_usd,
         (select cp.costo_real from costos_pedido_v cp
           where cp.pedido_codigo = v.pedido_codigo and cp.perfume_id = v.perfume_id) as costo_unit
  from ventas v join perfumes pf on pf.id = v.perfume_id
) x;

-- ---------- 3. Merma por cobro en Bs y por pedido ----------
create or replace function binance_del_dia(p_fecha date) returns numeric
language sql stable as $f$
  select coalesce(
    (select binance from tasas where fecha <= p_fecha order by fecha desc limit 1),
    (select binance from tasas order by fecha limit 1))
$f$;

create or replace view merma_cobros_v with (security_invoker = true) as
select co.id as cobro_id, co.fecha, v.pedido_codigo, v.cliente, co.monto as bs,
       coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) as tasa_bcv,
       binance_del_dia(co.fecha::date) as binance_dia,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv), 2) as nominal_usd,
       round(co.monto / binance_del_dia(co.fecha::date), 2) as real_usd,
       round(co.monto / coalesce(co.tasa_bcv, co.tasa_binance, v.tasa_bcv) - co.monto / binance_del_dia(co.fecha::date), 2) as merma_usd
from cobros co join ventas v on v.id = co.venta_id
where co.cuenta = 'bs';

create or replace view merma_pedido_v with (security_invoker = true) as
select coalesce(pedido_codigo, 'Sin pedido') as pedido_codigo,
       count(*)::int as cobros_bs, round(sum(bs), 2) as bs,
       round(sum(nominal_usd), 2) as nominal_usd, round(sum(real_usd), 2) as real_usd,
       round(sum(merma_usd), 2) as merma_usd
from merma_cobros_v group by 1;

-- ---------- 4. Datos del 30/10 al 1/11 (una sola vez) ----------
do $$
declare tv numeric; tb numeric; v_id bigint; pid bigint; ok_spl int;
begin
  if exists (select 1 from cargas_hechas where clave = 'v14_datos_1nov') then
    raise notice 'Los datos de v14 ya estaban cargados. No se repiten.'; return;
  end if;
  select coalesce(euro, bcv), binance into tv, tb from tasas order by fecha desc limit 1;
  if coalesce(tv, 0) <= 0 or coalesce(tb, 0) <= 0 then
    raise exception 'Primero guarda en "Finanzas > Tasas" la tasa de hoy (BCV $, BCV Euro y Binance) y vuelve a ejecutar esto.';
  end if;

  -- Lote 4: pagado con la caja ($345 en efectivo)
  insert into movimientos (fecha, cuenta, monto, nota) values ('2026-11-01', 'efectivo', -345, 'Pago del lote 4 (P-004) con la caja');

  -- Taxi para transportar los perfumes (sale de la caja, en efectivo)
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  values ('2026-10-30', 'traslado', 'Taxi para transportar los perfumes', 11, 'P-004', 'efectivo', 'Juan');

  -- Eduin Torres pagó sus $15 en Bs a BCV 994  ->  14.910 Bs
  select v.id into v_id from ventas_v v where lower(v.cliente) like 'eduin torre%' and v.pendiente_usd > 0.01 order by v.fecha, v.id limit 1;
  if v_id is null then raise exception 'No encontré una venta con saldo de Eduin Torres.'; end if;
  insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv) values (v_id, '2026-11-01', 'bs', 15 * 994, 994);

  -- Thank U Next: la segunda unidad también se la vendió a Keylin Cabrera por $25 en efectivo
  select id into pid from perfumes where lower(trim(nombre)) = 'ariana grande thank u next';
  if pid is null then raise exception 'No encuentro el perfume Ariana Grande Thank U Next.'; end if;
  insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, nota)
  values ('2026-10-30', 'Keylin Cabrera', 'Juan', pid, 'P-003', 1, 25, 'divisa', tv, tb, 'Segunda unidad del Thank U Next. Pagó en efectivo')
  returning id into v_id;
  insert into cobros (venta_id, fecha, cuenta, monto) values (v_id, '2026-10-30', 'efectivo', 25);

  -- Splash: en el pedido 3 llegaron 9 (no 10) por los mismos $26 en total
  update compras set unidades = 9, costo_unitario = round(26.0 / 9, 4)
   where pedido_codigo = 'P-003'
     and perfume_id = (select id from perfumes where nombre ilike 'Victoria Secret Splash%' order by id limit 1)
     and unidades = 10;
  get diagnostics ok_spl = row_count;
  if ok_spl = 0 then raise notice 'REVISAR: no encontré 10 splash en el pedido 3; corrige el splash a mano en Inventario.'; end if;

  insert into cargas_hechas (clave) values ('v14_datos_1nov');
end $$;

-- ---------- Permisos ----------
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function binance_del_dia(date) to authenticated;
  end if;
end $$;

-- >>>>>>>>>> migracion_v16.sql <<<<<<<<<<
-- =====================================================================
-- MIGRACIÓN v16 · REEMPLAZO de todas las ventas y cobros con la información correcta (lotes 1 a 4)
-- Ejecutar DESPUÉS de migracion_v14.sql (la v15 NO hace falta; si ya la corriste, esta la limpia).
-- ANTES: guarda un respaldo desde la app (Respaldo) y guarda hoy las tasas (Tasa del día).
--
-- QUÉ HACE
--  1. Borra TODAS las ventas y cobros actuales, las compras de divisa y los ajustes de caja de la v15.
--  2. Carga las 69 ventas de los lotes 1 a 4 con sus cobros (fecha, cuenta, monto y tasa de cada pago).
--  3. NO toca pedidos, compras, aportes de los socios, préstamos ni gastos (taxi $11 y arroz chino $20 se mantienen).
--  4. Registra la pérdida del Yara Candy defectuoso: 1 unidad menos en el P-003 y gasto operativo de $12 (sin tocar la caja).
--  5. Cuadra la caja con lo que hay a la mano: efectivo $67, Binance $76 y banco 2.600 Bs.
--     El dinero que sobra respecto a las ventas registradas queda como un INCISO aparte
--     ("Sobrante por conciliar"): está dentro del saldo real pero separado de lo que explican las ventas.
-- Se aplica UNA sola vez: si repites el archivo no duplica nada.
-- =====================================================================
alter table movimientos add column if not exists concilia boolean not null default false;

create or replace function norm_txt(t text) returns text language sql immutable as $f$
  select regexp_replace(translate(lower(coalesce(t, '')), 'áéíóúüñôèêàâ', 'aeiouunoeeaa'), '[^a-z0-9]+', '', 'g')
$f$;

do $$
declare
  r record; v_id bigint; f date; tb numeric; tcv numeric;
  falta text;
  t_ef constant numeric := 67; t_bin constant numeric := 76; t_bs constant numeric := 2600;
  s_ef numeric; s_bin numeric; s_bs numeric; bs_conv numeric; div numeric; pe numeric; pb numeric; tot numeric;
  a_e numeric; a_b numeric; bs_e numeric; bs_b numeric; delta numeric; cta text;
begin
  if exists (select 1 from cargas_hechas where clave = 'v16_reemplazo_ventas') then
    raise notice 'La v16 ya estaba aplicada. No se repite.'; return;
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'cobros' and column_name = 'tasa_bcv') then
    raise exception 'Primero ejecuta migracion_v14.sql.';
  end if;
  select binance into tb from tasas where binance > 0 order by fecha desc limit 1;
  if tb is null then raise exception 'Guarda primero las tasas de hoy en la app (Tasa del día).'; end if;

  drop table if exists _v16_v, _v16_c, _v16_p, _v16_old, _v16_id;
  -- ---------- Datos: ventas (n, lote, cliente, vendedor, perfume, unidades, total $, base, vence) ----------
  create temp table _v16_v (n int, ped text, cliente text, vend text, perfume text, unid int, total numeric, base text, vence date) on commit drop;
  insert into _v16_v values
   (1,'P-001','María Fernanda Kyomu','Juan','La Bomba Carolina Herrera',1,35,'divisa',null),
   (2,'P-001','Mildred Ramos','Juan','Meow Katy Perry',1,25,'divisa',null),
   (3,'P-001','Neysimar','Juan','Valentino Donna Intense',1,35,'divisa','2026-11-15'),
   (4,'P-001','Ender Barbero','George','Invictus Parfum Paco Rabanne',1,40,'divisa',null),
   (5,'P-001','Ender Barbero','George','Set de regalo Odyssey Collection',1,45,'divisa',null),
   (6,'P-001','Mildred Ramos','Juan','Fantasy',1,25,'divisa',null),
   (7,'P-001','Eduin Torres','Juan','9 PM Night Out',1,35,'divisa',null),
   (8,'P-002','Albany Rebolledo','Juan','Paris Hilton Can Can',1,35,'divisa',null),
   (9,'P-002','Luisa Teran','Juan','Afnan 9am Femme',1,25,'divisa',null),
   (10,'P-002','Carlos Zuñiga','Juan','Carolina Herrera Bad Boy',1,30,'divisa',null),
   (11,'P-002','Juan Montilva','Juan','Armaf Beach Party',1,20,'divisa',null),
   (12,'P-002','Rosalia Torres','Juan','Carolina Herrera 212 VIP Fem',1,30,'divisa',null),
   (13,'P-002','María Fernanda Kyomu','Juan','Orientica Amber Rouge',1,35,'divisa',null),
   (14,'P-002','Jesus Teran','Juan','Lattafa Khamrah Karaz Unisex Lujo Premium',1,40,'divisa',null),
   (15,'P-002','Jesus Teran','Juan','One Million Paco Rabanne',1,20,'divisa',null),
   (16,'P-002','Wuile Kyomu','Juan','Mont Blanc Starwalker Men',1,35,'divisa','2026-11-02'),
   (17,'P-002','Kyuran','Juan','Lacoste White Men',1,30,'divisa',null),
   (18,'P-002','Jean Mary de la Hoz','George','Armaf Odyssey Mega Men',1,30,'divisa',null),
   (19,'P-002','Jean Mary de la Hoz','George','Bharara Rose Fem Lujo Premium',1,30,'divisa',null),
   (20,'P-002','Doris Teran','Juan','Carolina Herrera Good Girl Fem',1,35,'divisa',null),
   (21,'P-002','José Montilva','Juan','Giorgio Armani Acqua di Gio Men',1,25,'divisa',null),
   (22,'P-002','Juan Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (23,'P-002','Dra. Yexi','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (24,'P-002','Luisa Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (25,'P-002','Kyuran','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (26,'P-002','Wuile Kyomu','Juan','Victoria Secret Splash 250ml (variados)',1,7,'divisa',null),
   (27,'P-002','María Fernanda Kyomu','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (28,'P-002','Lori Teran','Juan','Victoria Secret Splash 250ml (variados)',1,10,'divisa',null),
   (29,'P-002','Fabian Gago','Juan','Victoria Secret Splash 250ml (variados)',2,15,'bcv',null),
   (30,'P-002','Rosanny Cequea','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa',null),
   (31,'P-002','Anny Guitian','Juan','Victoria Secret Splash 250ml (variados)',2,15,'bcv',null),
   (32,'P-003','Lori Teran','Juan','Ariana Grande Cloud',1,25,'divisa',null),
   (33,'P-003','Keylin Cabrera','Juan','Ariana Grande Thank U Next',1,25,'divisa',null),
   (34,'P-003','Anny Guitian','Juan','Ariana Grande Thank U Next',1,35,'bcv',null),
   (35,'P-003','Jesus Teran','Juan','Bestia Negra',1,20,'divisa',null),
   (36,'P-003','Wuile Kyomu','Juan','Bestia Negra',1,30,'divisa',null),
   (37,'P-003','Almari','Juan','Bharara Rose Fem Lujo Premium',1,45,'bcv',null),
   (38,'P-003','Rosalba Guitian','Rosanny','Carolina Herrera Good Girl Fem',1,30,'divisa',null),
   (39,'P-003','Rosalba Montilva','Juan','Lancôme La Vie Est Belle',1,25,'divisa',null),
   (40,'P-003','Andreina (esposa de Ismael)','Wuilesmar','Lattafa Yara Clásico',1,25,'bcv',null),
   (41,'P-003','Jessica Green Hair','George','Lattafa Yara Candy Fem',1,30,'bcv','2026-11-17'),
   (42,'P-003','Jhoany Guitian','Rosanny','Lattafa Yara Candy Fem',1,35,'bcv',null),
   (44,'P-003','Jema de La Hoz','George','Paco Rabanne One Million Lucky',1,30,'divisa','2026-11-15'),
   (45,'P-003','Doris Teran','Juan','Fantasy',1,25,'divisa','2026-11-15'),
   (46,'P-003','Juan Perez','Juan','Armaf Odyssey Mandarin Sky Elixir',1,35,'divisa',null),
   (47,'P-003','Carola Carvajal','George','Armaf Odyssey Mandarin Sky Elixir',1,30,'divisa',null),
   (48,'P-003','Lori Teran','Juan','Ariana Grande Mod Blush',1,25,'divisa',null),
   (49,'P-003','Elvys Castillo','Juan','Victorinox Swiss Army Classic',1,25,'divisa',null),
   (50,'P-003','Jefren Carpintero','Jose Montilva','9 PM Night Out',1,35,'bcv',null),
   (51,'P-003','Juan Teran','Juan','9 PM Night Out',1,35,'divisa',null),
   (52,'P-003','Rosangela Cequea','Juan','Valentino Donna Fem',1,38,'bcv',null),
   (53,'P-003','Gina Pena','Rosanny','Victoria Secret Splash 250ml (variados)',4,36,'bcv',null),
   (54,'P-003','Doris Teran','Juan','Victoria Secret Splash 250ml (variados)',2,15,'divisa','2026-11-15'),
   (55,'P-003','Veronica','Gardimar','Carolina Herrera 212 VIP Rose Fem',1,25,'divisa',null),
   (56,'P-003','Carpintero','Jose Montilva','Bharara Viking Kashmir Lujo',1,45,'divisa',null),
   (57,'P-003','Carola Carvajal','George','Lattafa Yara Tous Fem',1,30,'divisa',null),
   (58,'P-003','Hijo del Carpintero','Jose Montilva','Afnan 9am Dive Unisex',1,35,'bcv','2026-11-15'),
   (59,'P-004','Jessica Green Hair','George','Bestia Negra',1,30,'divisa','2026-11-17'),
   (60,'P-004','Mauricio Garces','Juan','Mont Blanc Legend Spirit',1,25,'divisa',null),
   (61,'P-004','Cliente de Wuile (sin nombre)','Wuilesmar','Victoria Secret Splash 250ml (variados)',1,7,'divisa',null),
   (62,'P-004','Yeimy Green Hair','George','Bharara Rose Fem Lujo Premium',1,30,'divisa','2026-11-17'),
   (63,'P-004','Yeimy Green Hair','George','Lattafa Khamrah Karaz Unisex Lujo Premium',1,30,'divisa','2026-11-17'),
   (64,'P-004','Ariana Marquez','Juan','Carolina Herrera Good Girl Fem',1,35,'divisa','2026-11-30'),
   (65,'P-004','Veronica','Gardimar','9 PM Night Out',1,35,'divisa',null),
   (66,'P-004','Jean Mary de la Hoz','George','Armaf Odyssey Mandarin Sky',1,30,'divisa','2026-11-15'),
   (67,'P-004','Jesus Zapatero','Wuilesmar','Armaf Odyssey Mandarin Sky Elixir',1,25,'divisa',null),
   (68,'P-004','Rosanna Aqua Vic','Juan','Ariana Grande Mod Blush',1,35,'divisa','2026-11-02'),
   (69,'P-004','Felix Aqua Vic','Juan','Bharara Kinh Soleil Lujo Premium',1,40,'divisa','2026-11-15'),
   (70,'P-004','Adriana Aqua Vic','Juan','Armaf Odyssey Pink Pop Fem',1,35,'divisa',null);

  -- ---------- Datos: cobros (n de la venta, fecha, cuenta, monto, tasa BCV/Binance a la que pagó si es en Bs) ----------
  create temp table _v16_c (n int, fecha date, cuenta text, monto numeric, tasa numeric) on commit drop;
  insert into _v16_c values
   (2,null,'binance',25,null), (3,'2026-11-01','bs',14985,993),
   (4,'2026-10-15','bs',40000,1000), (5,'2026-10-15','bs',45000,1000), (6,null,'binance',25,null),
   (7,'2026-10-15','bs',20600,1030), (7,'2026-10-30','bs',14910,994),
   (8,'2026-10-30','bs',15561.97,889.25), (9,'2026-10-15','efectivo',25,null), (10,'2026-10-16','bs',30000,1000),
   (11,'2026-10-16','efectivo',20,null), (14,'2026-10-30','efectivo',40,null), (16,'2026-10-15','bs',19600,980),
   (20,'2026-10-30','efectivo',35,null), (21,null,'efectivo',20,null),
   (22,'2026-10-26','bs',15000,1000), (26,'2026-10-30','bs',6952,993.142857), (28,'2026-10-17','bs',9857.30,985.73),
   (29,'2026-10-15','bs',6607.95,881.06), (29,'2026-10-30','bs',6667.5,889),
   (31,'2026-10-26','bs',6660,886), (31,'2026-10-30','bs',6667.5,888),
   (32,'2026-10-29','bs',24734.72,989.3888), (33,'2026-10-23','efectivo',25,null), (37,'2026-10-30','bs',20002.5,889),
   (40,'2026-10-30','bs',16878,991), (46,'2026-10-30','efectivo',20,null), (50,'2026-10-26','bs',31080,888),
   (52,'2026-10-16','bs',16772.2,882.7), (53,'2026-10-26','bs',15984,888), (58,'2026-10-30','bs',17760,888),
   (60,'2026-10-22','bs',9930,993), (69,'2026-10-30','efectivo',20,null), (70,'2026-10-30','binance',35,null);

  -- ---------- Los perfumes deben existir (si falta alguno, no se toca nada) ----------
  create temp table _v16_p on commit drop as
    select distinct x.perfume, (select pf.id from perfumes pf where norm_txt(pf.nombre) = norm_txt(x.perfume) order by pf.id limit 1) as pid
    from _v16_v x;
  select string_agg(perfume, ', ') into falta from _v16_p where pid is null;
  if falta is not null then raise exception 'No se encontraron estos perfumes y no se aplicó nada: %', falta; end if;

  -- ---------- Se conservan las fechas de venta que ya estaban cuando se puede ----------
  create temp table _v16_old on commit drop as
    select perfume_id, pedido_codigo, lower(cliente) as cli, min(fecha) as fecha from ventas group by 1, 2, 3;

  -- ---------- Se borra lo anterior ----------
  delete from conversiones;
  delete from movimientos where concilia or nota like 'Ajuste al conteo real%';
  delete from ventas;   -- los cobros se borran con ellas

  -- ---------- Se cargan las ventas ----------
  create temp table _v16_id (n int, id bigint) on commit drop;
  for r in select x.*, p.pid, pe.fecha as fped,
                  (select min(c.fecha) from _v16_c c where c.n = x.n and c.fecha is not null) as fcob
           from _v16_v x join _v16_p p on p.perfume = x.perfume left join pedidos pe on pe.codigo = x.ped order by x.n
  loop
    f := coalesce((select o.fecha from _v16_old o where o.perfume_id = r.pid and o.pedido_codigo = r.ped and o.cli = lower(r.cliente)),
                  r.fcob, r.fped, current_date);
    insert into ventas (fecha, cliente, vendedor, perfume_id, pedido_codigo, unidades, precio_unit, base, tasa_bcv, tasa_binance, vence)
    values (f, r.cliente, r.vend, r.pid, r.ped, r.unid, round(r.total / r.unid, 4), r.base,
            coalesce((select bcv from tasas where fecha <= f and bcv > 0 order by fecha desc limit 1),
                     (select bcv from tasas where bcv > 0 order by fecha desc limit 1), tb),
            binance_del_dia(f), r.vence)
    returning id into v_id;
    insert into _v16_id values (r.n, v_id);
  end loop;

  insert into cobros (venta_id, fecha, cuenta, monto, tasa_bcv)
  select i.id, coalesce(c.fecha, v.fecha), c.cuenta, c.monto, c.tasa
  from _v16_c c join _v16_id i on i.n = c.n join ventas v on v.id = i.id;

  -- Canje de José Montilva: pagó $20 vendiendo perfumes, no entró plata a la caja
  insert into movimientos (fecha, cuenta, monto, nota)
  select v.fecha, 'efectivo', -20, 'Canje: José Montilva pagó $20 vendiendo perfumes (no entró a la caja)'
  from _v16_id i join ventas v on v.id = i.id where i.n = 21;

  -- ---------- Clientes: se limpian los nombres repetidos que no tienen datos ----------
  delete from clientes cl where cl.telefono is null and cl.notas is null
    and not exists (select 1 from ventas v where lower(v.cliente) = lower(cl.nombre));
  insert into clientes (nombre) select distinct v.cliente from ventas v
    where not exists (select 1 from clientes c where lower(c.nombre) = lower(v.cliente));

  -- ---------- Pérdida: 1 Yara Candy defectuoso en el P-003 ----------
  update compras set unidades = unidades - 1
   where pedido_codigo = 'P-003' and unidades >= 3
     and perfume_id = (select pid from _v16_p where perfume = 'Lattafa Yara Candy Fem');
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'otro', 'Pérdida de inventario: 1 Yara Candy defectuoso (P-003, costo $12)', 12, 'P-003', null, null
  where not exists (select 1 from gastos where concepto like 'Pérdida de inventario: 1 Yara Candy%');
  -- Gastos que se mantienen: taxi $11 y arroz chino $20 (se crean solo si faltan)
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'traslado', 'Taxi para transportar los perfumes', 11, 'P-004', 'efectivo', 'Juan'
  where not exists (select 1 from gastos where concepto ilike '%taxi%');
  insert into gastos (fecha, categoria, concepto, monto, pedido_codigo, cuenta, pagado_por)
  select '2026-10-30', 'otro', 'Arroz chino para comer', 20, null, 'efectivo', 'Juan'
  where not exists (select 1 from gastos where concepto ilike '%arroz chino%');

  -- ---------- Caja: efectivo $67, Binance $76, banco 2.600 Bs ----------
  select coalesce(max(saldo) filter (where cuenta = 'efectivo'), 0), coalesce(max(saldo) filter (where cuenta = 'binance'), 0),
         coalesce(max(saldo) filter (where cuenta = 'bs'), 0) into s_ef, s_bin, s_bs from caja_v;
  raise notice 'Caja según las ventas registradas: efectivo %, Binance %, Bs %.', round(s_ef, 2), round(s_bin, 2), round(s_bs, 2);

  -- Los Bs de más se registran como compra de divisa INFERIDA (sin merma; reemplázala con tus cifras reales)
  bs_conv := s_bs - t_bs;
  if bs_conv > 0.005 then
    div := round(bs_conv / tb, 2);
    pe := greatest(t_ef - s_ef, 0); pb := greatest(t_bin - s_bin, 0); tot := pe + pb;
    a_e := case when tot <= 0.005 then div else round(div * pe / tot, 2) end; a_b := div - a_e;
    bs_e := case when div > 0 then round(bs_conv * a_e / div, 2) else 0 end; bs_b := bs_conv - bs_e;
    if a_e > 0.005 then insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_e, a_e, 'efectivo', tb, 'Inferida (no tengo los datos reales de la compra): reemplázala con tus cifras'); end if;
    if a_b > 0.005 then insert into conversiones (fecha, bs, divisa, cuenta, tasa_bcv, nota)
      values ('2026-11-01', bs_b, a_b, 'binance', tb, 'Inferida (no tengo los datos reales de la compra): reemplázala con tus cifras'); end if;
  end if;

  -- Lo que aún difiere del conteo real se anota aparte, como inciso (concilia = true)
  for cta, delta in
    select c.cuenta, (case c.cuenta when 'efectivo' then t_ef when 'binance' then t_bin else t_bs end) - c.saldo
    from caja_v c where c.cuenta in ('efectivo', 'binance', 'bs')
  loop
    if abs(delta) > 0.005 then
      insert into movimientos (fecha, cuenta, monto, nota, concilia)
      values ('2026-11-01', cta, round(delta, 2),
              case when delta > 0 then 'Sobrante por conciliar: dinero en caja que no sale de las ventas registradas'
                   else 'Faltante por conciliar: la caja real es menor a lo que muestran las ventas' end, true);
    end if;
  end loop;

  insert into cargas_hechas (clave) values ('v16_reemplazo_ventas');
end $$;

-- >>>>>>>>>> migracion_v17.sql <<<<<<<<<<
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

-- >>>>>>>>>> migracion_v18.sql <<<<<<<<<<
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
