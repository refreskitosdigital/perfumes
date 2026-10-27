# Control de Perfumes · Juan & George

App web para llevar compras, ventas, inventario, caja, tasas (BCV/Binance) y agenda de pedidos.
Reparto de ganancias 50/50. Datos en Supabase, código en GitHub, publicada en Netlify.

## Instalación (una sola vez, ~20 minutos)

### 1. Supabase (la base de datos)
1. Entra a https://supabase.com, crea una cuenta y un **New project** (nombre: `perfumes`; guarda la clave de base de datos).
2. Menú **SQL Editor > New query**. Pega TODO el contenido de `supabase/schema.sql` y pulsa **Run**.
3. En **Authentication > Users > Add user > Create new user**, crea dos usuarios (correo y clave) para Juan y George. Marca *Auto Confirm User*.
4. En **Authentication > Sign In / Providers**, desactiva *Allow new users to sign up* (así nadie más puede registrarse).
5. En el **SQL Editor**, nueva consulta: pega y ejecuta `supabase/seed_pedidos_1_2.sql` (carga los pedidos 1 y 2 con sus ventas, cobros pendientes y el préstamo).
6. Luego ejecuta `supabase/seed_pedido_3.sql`: carga el pedido 3 (3 socios en partes iguales), los préstamos de REFRESKITO Digital y los correos de acceso de Juan, George y Rosanny.
7. Por último ejecuta `supabase/migracion_v3.sql` (clientes, pagos y el botón Realizar pedido). Es seguro repetirla.
8. Después ejecuta `supabase/migracion_v4.sql` (tienda online, fotos, pedidos web y demanda). Es seguro repetirla. Crea el bucket de fotos `perfumes`.
9. Después ejecuta `supabase/migracion_v5.sql` (banners, segunda foto, datos de entrega, tu WhatsApp). Es seguro repetirla.
10. Por último ejecuta `supabase/migracion_v6.sql` (una sola tasa de venta: BCV Euro; la Binance queda solo interna). Es seguro repetirla.
11. Ejecuta `supabase/migracion_v7.sql` (la tienda muestra TODOS los perfumes visibles, incluso los que aún no tienen precio: salen como "Precio por confirmar" y se pueden agendar). No modifica ni borra datos. Es seguro repetirla.
12. Ejecuta `supabase/migracion_v8.sql` (gastos, tablero de Rentabilidad y carga del lote 3: ventas, cobros, agenda y cambio Moschino → Bharara Viking). La carga se aplica una sola vez aunque la repitas. Antes de correrla, la tasa del día debe estar registrada en la pestaña Tasas.
13. Ejecuta `supabase/migracion_v9.sql` (Catálogo con 3 precios, descripciones, vendedoras con PIN, pedidos de vendedoras y sus cobros). Hay que haber corrido antes v4 → v8, en orden. Es seguro repetirla.
11. Tienda pública: `https://TU-SITIO.netlify.app/tienda`. Entra a **Tienda online → Ajustes** y coloca el WhatsApp (ej. 584141234567), el mínimo al mayor (12) y tus métodos de pago.
12. Banners: **Tienda online → Banners** (hasta 4, 1920 × 640 px). Fotos y precios: **Inventario → ✏️ Editar** (subir foto, cambiar precio y mostrar/ocultar en la tienda).
8. En **Project Settings > API** copia dos datos: **Project URL** y la clave **anon public**.

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
2. Opcional: en el sitio de control agrega `VITE_URL_VENDEDORAS` con esa dirección para verla y copiarla en la pestaña **Vendedoras**.
3. En **Vendedoras** crea a cada una con usuario y PIN (6 a 10 dígitos). Tras 5 intentos fallidos se bloquea 15 minutos.
4. En **Catálogo** completa para cada perfume los 3 precios: tienda (detal), mayor y consignación. Sin precio de consignación no aparece para las vendedoras. Regla: costo < consignación ≤ mayor ≤ detal (la app avisa si no cuadra).
5. Regla de cobro: la perfumería cobra primero su consignación; lo que el cliente pague por encima de ella es ganancia de la vendedora. Ej.: consigna $25, venta $35 → los primeros $25 cobrados son de la perfumería y los últimos $10 de ella.
6. Flujo: ellas agendan el pedido → tú lo apruebas en **Vendedoras** → se crean las ventas al precio de consignación → ellas anotan cobros (quién, cuándo, cuánto) y tú registras con **Recibir pago** lo que te entregan.
