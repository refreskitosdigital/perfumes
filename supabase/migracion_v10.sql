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
