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
7. En **Project Settings > API** copia dos datos: **Project URL** y la clave **anon public**.

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
