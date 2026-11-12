-- ============================================================
-- MIGRACIÓN v27 · Rebranding de la tienda MOTOSA
--  1. Perfumes: familia olfativa, ocasión, duración, "nuevo" (filtros, quiz y etiquetas de la tienda).
--  2. Tienda: enlace de Instagram y enlace de las cajas al mayor (ajustables desde el panel).
--  3. Clientes felices: fotos que subes tú desde el panel.
--  4. tienda_catalogo() y tienda_info() devuelven los campos nuevos.
--  5. Carga inicial de familia / ocasión / duración / notas (solo a perfumes que aún no las tienen).
-- Se puede ejecutar más de una vez sin problema.
-- ============================================================

-- ---------- 1. Perfumes ----------
alter table perfumes add column if not exists familia text;
alter table perfumes add column if not exists ocasion text;      -- ej. 'Salidas, Citas' (separadas por coma)
alter table perfumes add column if not exists duracion text;     -- ej. '5 a 7 horas'
alter table perfumes add column if not exists es_nuevo boolean not null default false;

-- ---------- 2. Ajustes de la tienda ----------
alter table tienda_config add column if not exists instagram_url text;
alter table tienda_config add column if not exists cajas_url text;
update tienda_config set instagram_url = 'https://www.instagram.com/motosaperfumes/?hl=es'
 where id = 1 and coalesce(instagram_url, '') = '';

-- ---------- 3. Clientes felices ----------
create table if not exists tienda_felices (
  id bigint generated always as identity primary key,
  orden int not null default 0,
  url text not null,
  nombre text,
  perfume text,
  activo boolean not null default true,
  creado timestamptz not null default now()
);
alter table tienda_felices enable row level security;
drop policy if exists solo_socios on tienda_felices;
create policy solo_socios on tienda_felices for all using (es_socio()) with check (es_socio());

-- ---------- 4. Lo que ve la tienda ----------
drop function if exists tienda_catalogo();
create or replace function tienda_catalogo()
returns table (id bigint, nombre text, precio_detal numeric, precio_mayor numeric, stock int,
               foto_url text, foto2_url text, vendidos int, descripcion text, marca text, genero text, notas text,
               familia text, ocasion text, duracion text, es_nuevo boolean)
language sql stable security definer set search_path = public as $$
  select pf.id, pf.nombre, pf.precio_detal, coalesce(pf.precio_mayor, pf.precio_detal),
         s.stock, pf.foto_url, pf.foto2_url, coalesce(v.u, 0)::int, pf.descripcion,
         nullif(trim(pf.marca), ''), pf.genero, nullif(trim(pf.notas), ''),
         nullif(trim(pf.familia), ''), nullif(trim(pf.ocasion), ''), nullif(trim(pf.duracion), ''), pf.es_nuevo
  from perfumes pf
  join stock_efectivo() s on s.perfume_id = pf.id
  left join (select perfume_id, sum(unidades) u from ventas group by perfume_id) v on v.perfume_id = pf.id
  where pf.visible_tienda
  order by pf.orden nulls last, pf.nombre;
$$;

create or replace function tienda_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nombre', c.nombre, 'whatsapp', c.whatsapp, 'umbral_mayor', c.umbral_mayor,
    'mensaje', c.mensaje, 'metodos', c.metodos,
    'instagram_url', c.instagram_url, 'cajas_url', c.cajas_url,
    'banners', coalesce((select jsonb_agg(b.url order by b.orden) from tienda_banners b where b.activo), '[]'::jsonb),
    'felices', coalesce((select jsonb_agg(jsonb_build_object('url', f.url, 'nombre', f.nombre, 'perfume', f.perfume) order by f.orden, f.id)
                         from tienda_felices f where f.activo), '[]'::jsonb),
    'tasa', (select to_jsonb(t) from (select fecha, coalesce(euro, bcv) as euro from tasas order by fecha desc limit 1) t)
  ) from tienda_config c where c.id = 1;
$$;

do $$
declare f text;
begin
  foreach f in array array['tienda_catalogo()', 'tienda_info()'] loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f); end if;
  end loop;
end $$;

-- ---------- 5. Carga inicial (propuesta: corrígela desde el panel, en Perfumes → Editar) ----------
do $$
declare r record;
begin
  if exists (select 1 from cargas_hechas where clave = 'v27_familias_notas') then return; end if;
  for r in select * from (values
    ('cloud$',          'Dulce',             'Día a día, Salidas',  '5 a 7 horas',  'Salida: lavanda, bergamota, pera · Corazón: coco, orquídea, jazmín · Fondo: vainilla, almizcle, sándalo'),
    ('yaracandy',       'Dulce',             'Salidas, Citas',      '5 a 7 horas',  'Salida: frutos rojos, mandarina · Corazón: rosa, orquídea · Fondo: vainilla, caramelo, almizcle'),
    ('goodgirl$',       'Floral',            'Noche, Citas',        '7 a 9 horas',  'Salida: almendra, café · Corazón: jazmín, tuberosa · Fondo: cacao, haba tonka, vainilla'),
    ('khamrahqahwa',    'Gourmand',          'Noche',               '8 a 10 horas', 'Salida: cardamomo, jengibre · Corazón: café, canela · Fondo: vainilla, haba tonka, praliné'),
    ('onemillion$',     'Ámbar y especiado', 'Salidas, Noche',      '6 a 8 horas',  'Salida: pomelo, menta · Corazón: canela, rosa · Fondo: cuero, ámbar, madera'),
    ('asad',            'Ámbar y especiado', 'Noche, Día a día',    '7 a 9 horas',  'Salida: pimienta negra, tabaco · Corazón: café, iris · Fondo: vainilla, ámbar, pachulí'),
    ('santal33',        'Amaderado',         'Día a día',           '6 a 8 horas',  'Salida: cardamomo, iris · Corazón: sándalo, papiro · Fondo: cuero, ámbar, cedro'),
    ('fantasy$',        'Dulce',             'Día a día, Salidas',  '4 a 6 horas',  'Salida: kiwi, lichi · Corazón: jazmín, orquídea · Fondo: almizcle, madera, pastel'),
    ('modblush',        'Floral',            'Día a día',           '4 a 6 horas',  'Salida: mandarina, ruibarbo · Corazón: rosa, peonía · Fondo: almizcle, ámbar'),
    ('invictus',        'Fresco',            'Día a día, Salidas',  '5 a 7 horas',  'Salida: pomelo, mandarina · Corazón: laurel, jazmín · Fondo: ámbar gris, madera, pachulí')
  ) as t(patron, familia, ocasion, duracion, notas)
  loop
    update perfumes set
      familia  = coalesce(nullif(trim(familia), ''), r.familia),
      ocasion  = coalesce(nullif(trim(ocasion), ''), r.ocasion),
      duracion = coalesce(nullif(trim(duracion), ''), r.duracion),
      notas    = coalesce(nullif(trim(notas), ''), r.notas)
    where norm_txt(nombre) ~ r.patron;
  end loop;
  insert into cargas_hechas (clave) values ('v27_familias_notas');
end $$;
