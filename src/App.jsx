import React, { createContext, useContext, useEffect, useState } from 'react'
import { supabase, configurado } from './supabase.js'
import { useQuery } from './hooks.js'
import { descuentoMax, factor, pct, tasaVenta } from './lib.js'
import Dashboard from './pages/Dashboard.jsx'
import Agenda from './pages/Agenda.jsx'
import Compras from './pages/Compras.jsx'
import Ventas from './pages/Ventas.jsx'
import Inventario from './pages/Inventario.jsx'
import Caja from './pages/Caja.jsx'
import PorCobrar from './pages/PorCobrar.jsx'
import Tasas from './pages/Tasas.jsx'
import Clientes from './pages/Clientes.jsx'
import Pagos from './pages/Pagos.jsx'
import TiendaOnline from './pages/TiendaOnline.jsx'
import Rentabilidad from './pages/Rentabilidad.jsx'
import Gastos from './pages/Gastos.jsx'
import Catalogo from './pages/Catalogo.jsx'
import Vendedoras from './pages/Vendedoras.jsx'
import ListaCompra from './pages/ListaCompra.jsx'
import Respaldo, { diasDesdeRespaldo } from './pages/Respaldo.jsx'
import { useCobrosHoy } from './pages/CobrosHoy.jsx'

const Ctx = createContext(null)
export const useApp = () => useContext(Ctx)

// [id, icono, nombre, qué se hace aquí, página]
const TABS = [
  ['dashboard', '🏠', 'Inicio', 'Cómo va el negocio hoy: plata, deudas y ganancias.', Dashboard],
  ['agenda', '🗓️', 'Agenda de pedidos', 'Planea lo que vas a comprar y, cuando se compre, pulsa Realizar pedido.', Agenda],
  ['listacompra', '🛒', 'Lista de compra', 'Todo lo que hay que comprar al proveedor: pedidos de vendedoras, de la tienda y agendados, menos lo que ya tienes.', ListaCompra],
  ['compras', '📥', 'Compras', 'Historial de lo que ya se compró a los proveedores.', Compras],
  ['catalogo', '🗂️', 'Catálogo', 'Perfumes que se publican en la tienda y a las vendedoras: nombre, descripción, fotos, 3 precios y existencia (estén o no en inventario).', Catalogo],
  ['vendedoras', '🤝', 'Vendedoras', 'Pedidos de Gardimar y Wuilesmar: aprobar, ver cuánto ganan y cuánto te deben.', Vendedoras],
  ['ventas', '🛍️', 'Ventas', 'Anota cada venta y lo que el cliente paga.', Ventas],
  ['clientes', '👥', 'Clientes', 'Quién compra, cuánto, cuánto debe y quiénes son los mejores.', Clientes],
  ['tienda', '🛒', 'Tienda online', 'Pedidos que llegan de la tienda web, perfumes agotados que piden y ajustes.', TiendaOnline],
  ['cobrar', '💵', 'Por cobrar', 'Lo que los clientes todavía nos deben.', PorCobrar],
  ['inventario', '📦', 'Inventario', 'Qué perfumes hay, cuáles se acaban y cuánto ganamos con cada uno.', Inventario],
  ['rentabilidad', '📊', 'Rentabilidad', 'Cuánto ganamos: total, por semana y mes, por pedido y por socio.', Rentabilidad],
  ['gastos', '💸', 'Gastos', 'Delivery, traslados y otros gastos que bajan la ganancia.', Gastos],
  ['caja', '🏦', 'Caja', 'El dinero que tenemos, en cada cuenta.', Caja],
  ['pagos', '🧾', 'Pagos', 'Lo que pagamos a proveedores y lo que devolvemos de los préstamos.', Pagos],
  ['respaldo', '💾', 'Respaldo y Excel', 'Descarga todos tus datos (respaldo semanal) o cualquier tabla en Excel.', Respaldo],
  ['tasas', '💱', 'Tasa del día', 'La tasa BCV Euro de hoy (tienda y ventas) y la Binance interna. Hay que ponerla antes de vender.', Tasas],
]
const GRUPOS = [
  ['', ['dashboard']],
  ['Comprar', ['listacompra', 'agenda', 'compras']],
  ['Vender', ['ventas', 'vendedoras', 'tienda', 'clientes', 'cobrar']],
  ['Dinero', ['rentabilidad', 'caja', 'gastos', 'pagos', 'tasas']],
  ['Productos', ['catalogo', 'inventario']],
  ['Sistema', ['respaldo']],
]

function Login() {
  const [email, setEmail] = useState('')
  const [clave, setClave] = useState('')
  const [error, setError] = useState('')
  const entrar = async (e) => {
    e.preventDefault()
    setError('')
    const { error } = await supabase.auth.signInWithPassword({ email, password: clave })
    if (error) setError('Correo o clave incorrectos.')
  }
  return (
    <main className="login">
      <form onSubmit={entrar}>
        <h1>🌸 Control de Perfumes</h1>
        <p className="ayuda">Acceso solo para los socios.</p>
        {!configurado && <div className="aviso error">Faltan las claves de Supabase (ver README, paso 4).</div>}
        <label className="campo"><span>Correo</span><input type="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label className="campo"><span>Clave</span><input type="password" value={clave} onChange={(e) => setClave(e.target.value)} required /></label>
        {error && <div className="aviso error">{error}</div>}
        <button className="primario" type="submit">Entrar</button>
      </form>
    </main>
  )
}

function Shell({ session }) {
  const [tab, setTab] = useState('dashboard')
  const socio = useQuery(() => supabase.from('socios').select('*'), [])
  const tasas = useQuery(() => supabase.from('tasas').select('*').order('fecha', { ascending: false }), [])
  const cfg = useQuery(() => supabase.from('config').select('*').eq('id', 1), [])
  const perfumes = useQuery(() => supabase.from('perfumes').select('*').order('sku'), [])
  const nuevosWeb = useQuery(() => supabase.from('pedidos_web').select('id').eq('estado', 'nuevo'), [])
  const nuevosVend = useQuery(() => supabase.from('pedidos_vendedora').select('id').eq('estado', 'pendiente'), [])
  useEffect(() => { const t = setInterval(() => { nuevosWeb.recargar(); nuevosVend.recargar() }, 60000); return () => clearInterval(t) }, []) // eslint-disable-line

  const cobrosHoy = useCobrosHoy()
  const miSocio = socio.data.find((s) => s.email.toLowerCase() === session.user.email.toLowerCase())
  const tasa = tasas.data[0] || null
  const config = cfg.data[0] || { ganancia_objetivo: 0.3, redondeo: 0.5, umbral_mayor: 6, base_ganancia: 'costo' }
  const nombresSocios = socio.data.map((x) => x.nombre).sort()
  const valor = { socios: nombresSocios, tasa, tasas, config, perfumes, miSocio, recargarTasas: tasas.recargar, recargarPerfumes: perfumes.recargar }
  const actual = TABS.find((t) => t[0] === tab)
  const Pagina = actual[4]

  if (!socio.cargando && !miSocio) {
    return (
      <main className="login"><div>
        <h1>Sin acceso</h1>
        <p>El correo {session.user.email} no está en la lista de socios.</p>
        <button onClick={() => supabase.auth.signOut()}>Salir</button>
      </div></main>
    )
  }

  return (
    <Ctx.Provider value={valor}>
      <div className="app">
        <header className="barra">
          <div className="marca">🌸 Perfumes <span>{nombresSocios.join(' · ')}</span></div>
          <div className="tasa-pill" title="Con esta tasa se calculan los precios y los Bs">
            {tasa ? <>Tasa de hoy · BCV Euro <b>{tasaVenta(tasa)}</b> · Binance (interna) <b>{tasa.binance}</b></> : <button className="link" onClick={() => setTab('tasas')}>⚠️ Falta la tasa de hoy</button>}
          </div>
          <div className="usuario">👤 {miSocio?.nombre} <button onClick={() => supabase.auth.signOut()}>Salir</button></div>
        </header>
        <div className="cuerpo">
          <nav className="menu" aria-label="Menú principal">
            {GRUPOS.map(([titulo, ids]) => (
              <div className="grupo" key={titulo || 'inicio'}>
                {titulo && <div className="grupo-titulo">{titulo}</div>}
                {ids.map((id) => {
                  const t = TABS.find((x) => x[0] === id)
                  return (
                    <button key={id} className={id === tab ? 'activa' : ''} onClick={() => { setTab(id); window.scrollTo({ top: 0 }) }}>
                      <span className="icono" aria-hidden="true">{t[1]}</span><span className="nombre">{t[2]}</span>
                      {id === 'tienda' && nuevosWeb.data.length > 0 && <span className="num-badge" aria-label={`${nuevosWeb.data.length} pedidos nuevos`}>{nuevosWeb.data.length}</span>}
                      {id === 'cobrar' && cobrosHoy.cantidad > 0 && <span className="num-badge" aria-label={`${cobrosHoy.cantidad} cobros de hoy`}>{cobrosHoy.cantidad}</span>}
                      {id === 'respaldo' && (diasDesdeRespaldo() == null || diasDesdeRespaldo() >= 7) && <span className="num-badge" aria-label="Toca respaldo semanal">!</span>}
                      {id === 'vendedoras' && nuevosVend.data.length > 0 && <span className="num-badge" aria-label={`${nuevosVend.data.length} pedidos por aprobar`}>{nuevosVend.data.length}</span>}
                    </button>
                  )
                })}
              </div>
            ))}
          </nav>
          <main className="contenido">
            <div className="titulo-pagina">
              <h1>{actual[1]} {actual[2]}</h1>
              <p>{actual[3]}</p>
            </div>
            <Pagina />
          </main>
        </div>
      </div>
    </Ctx.Provider>
  )
}

export default function App() {
  const [session, setSession] = useState(undefined)
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])
  if (session === undefined) return <main className="login"><p>Cargando…</p></main>
  return session ? <Shell session={session} /> : <Login />
}
