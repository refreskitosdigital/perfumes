# Control de Perfumes · Juan & George

App web para llevar compras, ventas, inventario, caja, tasas (BCV/Binance) y agenda de pedidos.
Reparto de ganancias 50/50. Datos en Supabase, código en GitHub, publicada en Netlify.

## Instalación (una sola vez, ~20 minutos)

### 1. Supabase (la base de datos)
**Camino rápido (proyecto de Supabase nuevo y vacío)**
1. Entra a https://supabase.com, crea una cuenta y un **New project** (nombre: `perfumes`; guarda la clave de base de datos).
2. **SQL Editor > New query**: abre `supabase/00_instalacion_completa.sql`, busca el bloque **EDITA ESTAS 3 CIFRAS** y escribe las tasas de hoy (BCV Euro, Binance y BCV $). Pega TODO el archivo y pulsa **Run**. Carga el esquema, los pedidos 1 a 4, las ventas, los cobros y todas las migraciones (v3 a v13) en el orden correcto.
3. **Authentication > Users > Add user > Create new user**: crea los usuarios de Juan, George y Rosanny con los mismos correos de la tabla `socios` (marca *Auto Confirm User*).
4. **Authentication > Sign In / Providers**: desactiva *Allow new users to sign up*.
5. **Project Settings > API**: copia el **Project URL** y la clave **anon public** (se usan al publicar).

**Camino por pasos (si ya tienes la base y solo te falta una parte)** ejecuta, en este orden y solo lo que no hayas corrido: `schema.sql`, `seed_pedidos_1_2.sql`, `seed_pedido_3.sql`, `migracion_v3.sql` … `migracion_v7.sql`, guardar las 3 tasas de hoy en la app (*Tasa del día*), `migracion_v8.sql`, `v9`, `v10`, `v11`, `v12`, `cobros_30oct.sql` y `migracion_v13.sql`. Las v11 a v13 también vienen juntas en `entrega_v11_a_v13.sql`. Todas se pueden repetir sin duplicar datos (las cargas se anotan en `cargas_hechas`).

**Después de publicar:** la tienda pública está en `/tienda`. Entra a **Tienda online → Ajustes** y coloca el WhatsApp (ej. 584141234567), el mínimo al mayor (12) y tus métodos de pago. Banners en **Tienda online → Banners** (hasta 4, 1920 × 640 px). Fotos y precios en **Inventario → ✏️ Editar**.

### 2. GitHub (el código)
1. Crea un repositorio nuevo **privado** en https://github.com (ej. `control-perfumes`).
2. Sube el contenido de esta carpeta (en el repositorio: *Add file > Upload files*). No subas `node_modules` ni `.env`.

### 3. Netlify (publicar)
1. En https://netlify.com: **Add new site > Import an existing project > GitHub** y elige el repositorio.
2. Netlify detecta solo la configuración (`netlify.toml`).
3. Antes de desplegar, en **Site configuration > Environment variables** agrega:
   - `VITE_SUPABASE_URL` = el Project URL
   - `VITE_SUPABASE_ANON_KEY` = la clave anon public
4. **Deploy**. Cada cambio que se suba a GitHub se publica solo.

### 4. Probar en tu computador (opcional)
```
cp .env.example .env     # y completa las dos claves
npm install
npm run dev
npm test                 # pruebas de las reglas de precios
```

## Qué trae
- **Dashboard**: inversión, ingresos, ganancia, 50/50, dinero en Binance/efectivo/Bs, top 5, por reponer.
- **Agenda**: pedidos próximos (no cuentan en inventario) con botón **Registrar**.
- **Compras**: costo real con envío repartido y precio sugerido (30 %, redondeo $0.50) en cada línea.
- **Ventas**: precio de lista en BCV$, equivalente en Bs y en divisa con descuento, precio al mayor desde 6 unidades.
- **Inventario**: SKU automático, stock, costo, rentabilidad detal/mayor. Los precios se editan ahí.
- **Caja**: saldos por cuenta y movimientos manuales.
- **Tasas**: BCV y Binance diarios; cada venta guarda la tasa con la que se hizo.

Los parámetros (30 %, 6 unidades, redondeo) están en la tabla `config` de Supabase (Table Editor).

## Cómo funciona el reparto con 3 socios
- Cada **pedido** tiene sus propios socios y su % de ganancia (proporcional a lo aportado). Los pedidos 1 y 2 son Juan 50 % / George 50 %.
- Al registrar el pedido 3 marcas a Rosanny (y a quien participe) en *Socios de este pedido*. Su ganancia solo viene de las ventas de ese pedido.
- Cada **venta** sale de un pedido (por defecto el más antiguo con stock) y su ganancia se reparte con los socios de ESE pedido.
- Una venta sin stock queda **anticipada** (sin pedido, stock negativo). Cuando se compre, se le asigna el pedido.

## Supuestos usados al cargar los pedidos 1 y 2 (revisar)
- Fechas de ventas = fecha de la compra (07/10 y 16/10); corregirlas si hace falta.
- Ventas en Bs o "a tasa BCV" (Neysimar, Albany, Gina, Fabian, Rosangela) se tomaron con precio en BCV$: valen precio × BCV / Binance.
- Binance del 16/10 asumido en 1015 (usa la pestaña Tasas para corregirlo). Lori pagó a 985, tomado como su tasa.
- Los 8 modelos de splash se cargaron como un solo producto (16 unidades a $3, lo facturado).
- Meow + Fantasy ($45 combo) se dividió $22,50 cada uno. Jean Mary: $60 por Binance, $30 por perfume.
- Préstamo de $254 por el pedido 2; prestamista: REFRESKITO Digital.

## Notas
- Los Bs recibidos se valoran a la tasa Binance (con la que se repone la divisa).
- Supabase gratis pausa el proyecto tras 7 días sin uso; se reactiva desde su panel.


## Dos sitios, un mismo código (tienda y control con dominios distintos)
1. Sitio de **control** (el que ya tienes): no necesita cambios. Opcional: variable `VITE_URL_TIENDA` con la dirección de la tienda.
2. Crea un **segundo sitio en Netlify** desde el MISMO repositorio de GitHub y agrega la variable `VITE_MODO` = `tienda` (Site configuration > Environment variables). Ese sitio abre la tienda en `/`.
3. Cada sitio puede tener su propio dominio (Domain management > Add a domain). Ambos usan la misma base de datos de Supabase.
4. Después de agregar variables, haz **Deploys > Trigger deploy > Clear cache and deploy site**.


## Link de vendedoras (Gardimar y Wuilesmar)
1. Crea un **tercer sitio en Netlify** desde el MISMO repositorio y agrega las variables `VITE_MODO` = `vendedoras`, `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` (las mismas de los otros sitios). Luego **Clear cache and deploy site**. También funciona en `/vendedoras` del sitio de control.
2. Agrega también `VITE_URL_TIENDA` con la dirección de la tienda (para que el botón «Compartir por WhatsApp» de la ficha incluya el link del perfume). Opcional: en el sitio de control agrega `VITE_URL_VENDEDORAS` con esa dirección para verla y copiarla en la pestaña **Vendedoras**.
3. En **Vendedoras** crea a cada una con usuario y PIN (6 a 10 dígitos). Tras 5 intentos fallidos se bloquea 15 minutos.
4. En **Catálogo** completa para cada perfume los 3 precios: tienda (detal), mayor y consignación. Sin precio de consignación no aparece para las vendedoras. Regla: costo < consignación ≤ mayor ≤ detal (la app avisa si no cuadra).
5. Regla de cobro: la perfumería cobra primero su consignación; lo que el cliente pague por encima de ella es ganancia de la vendedora. Ej.: consigna $25, venta $35 → los primeros $25 cobrados son de la perfumería y los últimos $10 de ella.
6. Flujo: ellas agendan el pedido → tú lo apruebas en **Vendedoras** → se crean las ventas al precio de consignación → ellas anotan cobros (quién, cuándo, cuánto) y tú registras con **Recibir pago** lo que te entregan.


## Ficha de perfume y link compartible
- Cada perfume tiene su ficha en la tienda: al tocar su foto o nombre se abre con fotos, descripción, notas y precios. El link es `https://TU-TIENDA/p/ID` (también copiable con **Copiar link**).
- **Compartir por WhatsApp** abre WhatsApp con el mensaje armado; la persona solo elige el contacto y envía. No tiene costo.
- La vista previa del link (foto, nombre y precio) la genera una función de Netlify incluida en `netlify/functions/ficha.js`; funciona con el plan gratuito y usa las mismas variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` del sitio. En el sitio de la tienda debe existir `VITE_MODO=tienda`.

## Otras funciones nuevas (v10)
- **Lista de compra** (Comprar): por perfume, lo que falta = pedidos de la tienda sin atender + clientes que agendaron − existencia − lo ya incluido en una agenda de compra. La existencia negativa son ventas ya hechas (p. ej. pedidos de vendedoras aprobados) que hay que comprar. Se copia o se baja en Excel.
- **Cobros de hoy** (Inicio y Por cobrar, con globo en el menú): clientes cuya fecha de pago es hoy o ya pasó, y pedidos de vendedoras cuyo cliente debía pagar; con botón de recordatorio por WhatsApp.
- **Respaldo y Excel** (Sistema): descarga todo en Excel (una hoja por tabla) o en JSON, o una tabla suelta. El menú muestra un «!» si pasaron 7 días sin respaldo. Nunca se descargan los PIN de las vendedoras.
- **Tienda**: filtros por género (mujer, hombre, unisex) y por marca. En el Catálogo, el filtro «Sin marca o sin género» ayuda a completar los que faltan.
- **Vendedoras**: ficha completa con descripción, notas y «Cómo venderlo» (solo para ellas); botón «Avisar por WhatsApp» al enviar un pedido; y «Te toca cobrar» con recordatorio al cliente.

## Catálogo en PDF (sin precios)
En **Catálogo** hay una sección «Catálogo en PDF»: genera un PDF con portada y 9 perfumes por página (foto, marca, género, nombre y, si quieres, notas) de todos los perfumes que están en la tienda. No incluye precios ni existencias. Puedes limitarlo a los que tienes en existencia. Se genera en tu navegador con los datos y fotos actuales, así que vuelve a generarlo cuando cambien. Para que salga la marca y las notas debe estar corrida la migración v10.

16. Ejecuta `supabase/migracion_v12.sql` (cierre del lote 3 con lo que quedó en existencia). Antes guarda en *Tasa del día* las 3 tasas de hoy (BCV Euro, Binance y BCV $). Se aplica una sola vez.

## Novedades v11
- **Tasa del día**: campo opcional *BCV $* (interna, nunca sale en la tienda) para calcular la merma.
- **Caja**: Efectivo $, Binance $, Bolívares y *Wallet total*. Mientras haya Bs sin convertir, el total dice "estimado" (Bs a tasa Binance). En *Convertir bolívares en divisa* anotas los Bs entregados y la divisa recibida: los Bs salen, la divisa entra y se calcula la merma (Bs ÷ BCV $ − divisa recibida). La merma se resta de la ganancia neta en Rentabilidad.
- **Inventario**: *Orden en la tienda* (arrastra con ☰ o usa ▲ ▼) y nombre editable en ✏️ Editar. La tienda y las vendedoras siguen ese orden, haya o no stock.
- **Clientes**: ✏️ en cada compra para corregir fecha, unidades y precio, y editar, agregar o borrar sus cobros.
- **Tienda**: etiquetas *Disponible* y *Por llegar pronto* (agotado).
- **Caja → Conteo real**: escribes lo que de verdad hay (banco Bs, efectivo, Binance), ves la diferencia contra el sistema y la ajustas con un botón.

## Publicar sin Netlify
- **Vercel** (gratis): importa el repositorio y agrega las mismas variables (`VITE_MODO`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_URL_TIENDA`, `VITE_URL_VENDEDORAS`). `vercel.json` ya trae las rutas y `api/ficha.js` la vista previa del link `/p/ID`. Un proyecto por sitio (control, tienda, vendedoras), todos del mismo repositorio.
- **Cloudflare Pages** (gratis): build `npm run build`, carpeta `dist`, mismas variables. Funciona la tienda y los links `?p=ID`; la vista previa bonita de `/p/ID` en WhatsApp solo existe en Netlify y Vercel.
- Las migraciones v11 a v13 también vienen juntas en `supabase/entrega_v11_a_v13.sql`.
