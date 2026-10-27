import React, { lazy, Suspense } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App.jsx'
import './styles.css'

// Dos formas de publicar el mismo código:
//  - Sitio de la TIENDA: variable VITE_MODO=tienda  -> la raíz "/" abre la tienda pública.
//  - Sitio de CONTROL (sin variable): app de los socios; "/tienda" sigue funcionando
//    (o redirige a VITE_URL_TIENDA si la defines).
const Tienda = lazy(() => import('./tienda/Tienda.jsx'))
const Vendedoras = lazy(() => import('./vendedoras/VendedorasApp.jsx'))
const modo = (import.meta.env.VITE_MODO || '').toLowerCase()
const urlTienda = (import.meta.env.VITE_URL_TIENDA || '').replace(/\/+$/, '')
const enRutaTienda = window.location.pathname.replace(/\/+$/, '').toLowerCase() === '/tienda'

if (modo !== 'tienda' && enRutaTienda && urlTienda) {
  window.location.replace(urlTienda)
}
const verTienda = modo === 'tienda' || enRutaTienda
// Tercer sitio: link de las vendedoras (VITE_MODO=vendedoras). También responde en /vendedoras.
const enRutaVend = window.location.pathname.replace(/\/+$/, '').toLowerCase() === '/vendedoras'
const verVendedoras = modo === 'vendedoras' || enRutaVend
createRoot(document.getElementById('root')).render(
  verVendedoras ? <Suspense fallback={null}><Vendedoras /></Suspense>
    : verTienda ? <Suspense fallback={null}><Tienda /></Suspense> : <App />
)
