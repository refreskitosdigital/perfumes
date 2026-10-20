import React, { createContext, useContext, useEffect, useState } from 'react'
import { supabase, configurado } from './supabase.js'
import { useQuery } from './hooks.js'
import { descuentoMax, factor, pct } from './lib.js'
import Dashboard from './pages/Dashboard.jsx'
import Agenda from './pages/Agenda.jsx'
import Compras from './pages/Compras.jsx'
import Ventas from './pages/Ventas.jsx'
import Inventario from './pages/Inventario.jsx'
import Caja from './pages/Caja.jsx'
import PorCobrar from './pages/PorCobrar.jsx'
import Tasas from './pages/Tasas.jsx'

const Ctx = createContext(null)
export const useApp = () => useContext(Ctx)

const TABS = [
  ['dashboard', 'Dashboard', Dashboard],
  ['agenda', 'Agenda', Agenda],
  ['compras', 'Compras', Compras],
  ['ventas', 'Ventas', Ventas],
  ['cobrar', 'Por cobrar', PorCobrar],
  ['inventario', 'Inventario', Inventario],
  ['caja', 'Caja', Caja],
  ['tasas', 'Tasas', Tasas],
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
        <h1>Control de Perfumes</h1>
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

  const miSocio = socio.data.find((s) => s.email.toLowerCase() === session.user.email.toLowerCase())
  const tasa = tasas.data[0] || null
  const config = cfg.data[0] || { ganancia_objetivo: 0.3, redondeo: 0.5, umbral_mayor: 6, base_ganancia: 'costo' }
  const nombresSocios = socio.data.map((x) => x.nombre).sort()
  const valor = { socios: nombresSocios, tasa, tasas, config, perfumes, miSocio, recargarTasas: tasas.recargar, recargarPerfumes: perfumes.recargar }
  const Pagina = TABS.find((t) => t[0] === tab)[2]

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
          <div className="marca">Perfumes <span>{nombresSocios.join(' · ')}</span></div>
          <div className="tasa-pill">
            {tasa ? (
              <>BCV {tasa.bcv} · Binance {tasa.binance} · Desc. máx {pct(descuentoMax(tasa.bcv, tasa.binance))} · ×{factor(tasa.bcv, tasa.binance).toFixed(4)}</>
            ) : 'Registra la tasa de hoy'}
          </div>
          <div className="usuario">{miSocio?.nombre} <button onClick={() => supabase.auth.signOut()}>Salir</button></div>
        </header>
        <nav className="tabs">
          {TABS.map(([k, t]) => (
            <button key={k} className={k === tab ? 'activa' : ''} onClick={() => setTab(k)}>{t}</button>
          ))}
        </nav>
        <main className="contenido"><Pagina /></main>
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
