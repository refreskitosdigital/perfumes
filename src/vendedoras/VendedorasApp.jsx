import React, { useCallback, useEffect, useMemo, useState } from 'react'
import { supabase, configurado } from '../supabase.js'
import { hoy, num } from '../lib.js'
import './vend.css'

const $ = (v) => '$' + num(v).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const corta = (f) => (f ? String(f).slice(8, 10) + '/' + String(f).slice(5, 7) : '')
const guardarSesion = (s) => { try { s ? sessionStorage.setItem('vend-sesion', JSON.stringify(s)) : sessionStorage.removeItem('vend-sesion') } catch { /* sin almacenamiento */ } }
const leerSesion = () => { try { return JSON.parse(sessionStorage.getItem('vend-sesion') || 'null') } catch { return null } }
const ESTADO = { pendiente: ['pen', 'Esperando aprobación'], aprobado: ['apr', 'Aprobado'], entregado: ['ent', 'Entregado'], rechazado: ['rec', 'Rechazado'] }

export default function VendedorasApp() {
  const [sesion, setSesion] = useState(leerSesion)
  const salir = useCallback(() => { guardarSesion(null); setSesion(null) }, [])
  return sesion
    ? <Panel sesion={sesion} salir={salir} />
    : <Entrar onEntrar={(s) => { guardarSesion(s); setSesion(s) }} />
}

function Entrar({ onEntrar }) {
  const [usuario, setUsuario] = useState('')
  const [pin, setPin] = useState('')
  const [error, setError] = useState('')
  const [cargando, setCargando] = useState(false)
  const entrar = async (e) => {
    e.preventDefault(); setError(''); setCargando(true)
    const { data, error: err } = await supabase.rpc('vend_entrar', { p_usuario: usuario, p_pin: pin })
    setCargando(false)
    if (err) return setError(/not find|schema cache/.test(err.message) ? 'El sistema todavía no está listo. Avisa a la perfumería.' : err.message)
    if (!data?.ok) return setError(data?.mensaje || 'No se pudo entrar')
    onEntrar({ token: data.token, nombre: data.nombre })
  }
  return (
    <main className="vend vend-login">
      <form onSubmit={entrar}>
        <h1>MOTOSA PARFUM</h1>
        <p>Acceso para vendedoras</p>
        {!configurado && <div className="v-aviso err">Faltan las claves de Supabase (ver README).</div>}
        <label>Usuario<input value={usuario} onChange={(e) => setUsuario(e.target.value)} autoCapitalize="none" autoComplete="username" required /></label>
        <label>PIN<input type="password" inputMode="numeric" pattern="[0-9]*" value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))} autoComplete="current-password" required /></label>
        {error && <div className="v-aviso err" role="alert">{error}</div>}
        <button className="v-btn" type="submit" disabled={cargando}>{cargando ? 'Entrando…' : 'Entrar'}</button>
      </form>
    </main>
  )
}

function Panel({ sesion, salir }) {
  const [vista, setVista] = useState('catalogo')
  const [catalogo, setCatalogo] = useState([])
  const [pedidos, setPedidos] = useState([])
  const [carro, setCarro] = useState([])     // [{id, unidades, precio}]
  const [error, setError] = useState('')
  const [ok, setOk] = useState('')

  const manejar = useCallback((err) => {
    if (/sesión venció/i.test(err.message)) return salir()
    setError(err.message)
  }, [salir])
  const cargar = useCallback(async () => {
    const [c, p] = await Promise.all([
      supabase.rpc('vend_catalogo', { p_token: sesion.token }),
      supabase.rpc('vend_mis_pedidos', { p_token: sesion.token }),
    ])
    if (c.error) return manejar(c.error)
    if (p.error) return manejar(p.error)
    setCatalogo(c.data || []); setPedidos(p.data || [])
  }, [sesion.token, manejar])
  useEffect(() => { cargar() }, [cargar])

  const aprobados = pedidos.filter((p) => p.estado === 'aprobado' || p.estado === 'entregado')
  const resumen = useMemo(() => ({
    ganado: aprobados.reduce((a, p) => a + num(p.ganada), 0),
    porCobrar: aprobados.reduce((a, p) => a + num(p.falta), 0),
    debo: aprobados.reduce((a, p) => a + num(p.debe_perfumeria), 0),
    pendientes: pedidos.filter((p) => p.estado === 'pendiente').length,
  }), [pedidos]) // eslint-disable-line

  const agregar = (p) => {
    setOk(''); setError('')
    setCarro((c) => (c.some((x) => x.id === p.id) ? c : [...c, { id: p.id, unidades: 1, precio: String(p.precio_sugerido ?? p.precio_consigna) }]))
    setVista('pedido')
  }

  return (
    <div className="vend">
      <header className="v-top">
        <div><b>MOTOSA PARFUM</b><span>Hola, {sesion.nombre}</span></div>
        <button className="v-link" onClick={salir}>Salir</button>
      </header>
      <nav className="v-tabs" aria-label="Secciones">
        {[['catalogo', 'Catálogo'], ['pedido', `Nuevo pedido${carro.length ? ` (${carro.length})` : ''}`], ['mis', `Mis pedidos${resumen.pendientes ? ` · ${resumen.pendientes}` : ''}`]].map(([k, t]) => (
          <button key={k} className={vista === k ? 'on' : ''} onClick={() => { setVista(k); setOk(''); setError('') }}>{t}</button>
        ))}
      </nav>
      <main className="v-cuerpo">
        {error && <div className="v-aviso err" role="alert">{error}</div>}
        {ok && <div className="v-aviso ok">{ok}</div>}
        {vista === 'catalogo' && <Catalogo lista={catalogo} agregar={agregar} enCarro={(id) => carro.some((x) => x.id === id)} />}
        {vista === 'pedido' && (
          <NuevoPedido token={sesion.token} catalogo={catalogo} carro={carro} setCarro={setCarro} manejar={manejar}
            enviado={() => { setCarro([]); setOk('¡Pedido enviado! Queda esperando la aprobación de la perfumería.'); setVista('mis'); cargar() }} />
        )}
        {vista === 'mis' && <MisPedidos token={sesion.token} pedidos={pedidos} resumen={resumen} recargar={cargar} manejar={manejar} />}
      </main>
    </div>
  )
}

function Catalogo({ lista, agregar, enCarro }) {
  const [q, setQ] = useState('')
  const filas = lista.filter((p) => p.nombre.toLowerCase().includes(q.toLowerCase()))
  return (
    <>
      <input className="v-buscar" placeholder="Buscar perfume…" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Buscar perfume" />
      {!lista.length && <p className="v-vacio">Todavía no hay perfumes con precio de consignación.</p>}
      <div className="v-grid">
        {filas.map((p) => (
          <article className="v-card" key={p.id}>
            <div className="v-foto">{p.foto_url ? <img src={p.foto_url} alt={p.nombre} loading="lazy" /> : <span aria-hidden="true">🧴</span>}</div>
            <h3>{p.nombre}</h3>
            {p.descripcion && <p className="v-desc">{p.descripcion}</p>}
            <div className="v-precios">
              <div><small>Tu precio (consignación)</small><b>{$(p.precio_consigna)}</b></div>
              {p.precio_sugerido != null && <div><small>Precio sugerido</small><b>{$(p.precio_sugerido)}</b></div>}
            </div>
            <small className={'v-disp ' + (p.disponible ? 'si' : 'no')}>{p.disponible ? 'Hay en existencia' : 'Se pide a la perfumería'}</small>
            <button className="v-btn" onClick={() => agregar(p)}>{enCarro(p.id) ? 'Ver en mi pedido' : 'Agregar al pedido'}</button>
          </article>
        ))}
      </div>
    </>
  )
}

function NuevoPedido({ token, catalogo, carro, setCarro, enviado, manejar }) {
  const [f, setF] = useState({ cliente: '', telefono: '', notas: '', plan: 'mitades', fecha1: '', fecha2: '' })
  const [enviando, setEnviando] = useState(false)
  const [error, setError] = useState('')
  const por = (id) => catalogo.find((p) => p.id === id)
  const lineas = carro.map((l) => ({ ...l, p: por(l.id) })).filter((l) => l.p)
  const venta = lineas.reduce((a, l) => a + num(l.unidades) * num(l.precio), 0)
  const perfumeria = lineas.reduce((a, l) => a + num(l.unidades) * num(l.p.precio_consigna), 0)
  const bajo = lineas.filter((l) => num(l.precio) < num(l.p.precio_consigna))
  const cambiar = (id, k, v) => setCarro((c) => c.map((l) => (l.id === id ? { ...l, [k]: v } : l)))

  const enviar = async (e) => {
    e.preventDefault(); setError('')
    if (!lineas.length) return setError('Agrega al menos un perfume desde el catálogo.')
    if (bajo.length) return setError(`El precio de ${bajo[0].p.nombre} no puede ser menor a ${$(bajo[0].p.precio_consigna)}.`)
    if (f.plan === 'mitades' && (!f.fecha1 || !f.fecha2)) return setError('Pon las fechas de los dos pagos.')
    setEnviando(true)
    const { error: err } = await supabase.rpc('vend_crear_pedido', {
      p_token: token, p_cliente: f.cliente, p_telefono: f.telefono, p_notas: f.notas, p_plan: f.plan,
      p_fecha1: f.plan === 'mitades' ? f.fecha1 : null, p_fecha2: f.plan === 'mitades' ? f.fecha2 : null,
      p_items: lineas.map((l) => ({ perfume_id: l.id, unidades: Math.round(num(l.unidades)), precio_venta: num(l.precio) })),
    })
    setEnviando(false)
    if (err) { if (/sesión venció/i.test(err.message)) return manejar(err); return setError(err.message) }
    enviado()
  }

  if (!lineas.length) return <p className="v-vacio">Tu pedido está vacío. Elige perfumes en el <b>Catálogo</b>.</p>
  return (
    <form onSubmit={enviar} className="v-form">
      <h2>Perfumes del pedido</h2>
      {lineas.map((l) => (
        <div className="v-linea" key={l.id}>
          <div className="v-linea-nombre"><b>{l.p.nombre}</b><small>Consignación {$(l.p.precio_consigna)}</small></div>
          <label>Unid.<input type="number" min="1" max="60" inputMode="numeric" value={l.unidades} onChange={(e) => cambiar(l.id, 'unidades', e.target.value)} required /></label>
          <label>Vendes a $<input type="number" step="0.01" min={l.p.precio_consigna} inputMode="decimal" value={l.precio} onChange={(e) => cambiar(l.id, 'precio', e.target.value)} required className={num(l.precio) < num(l.p.precio_consigna) ? 'mal' : ''} /></label>
          <div className="v-linea-gan">Ganas <b>{$((num(l.precio) - num(l.p.precio_consigna)) * num(l.unidades))}</b></div>
          <button type="button" className="v-x" onClick={() => setCarro((c) => c.filter((x) => x.id !== l.id))} aria-label={`Quitar ${l.p.nombre}`}>✕</button>
        </div>
      ))}
      <div className="v-totales">
        <div><small>El cliente paga</small><b>{$(venta)}</b></div>
        <div><small>Va a la perfumería</small><b>{$(perfumeria)}</b></div>
        <div className="gan"><small>Tu ganancia</small><b>{$(venta - perfumeria)}</b></div>
      </div>

      <h2>Cliente</h2>
      <label>Nombre del cliente<input value={f.cliente} onChange={(e) => setF({ ...f, cliente: e.target.value })} required /></label>
      <label>Teléfono (opcional)<input type="tel" inputMode="tel" value={f.telefono} onChange={(e) => setF({ ...f, telefono: e.target.value })} /></label>
      <label>¿Cómo va a pagar?
        <select value={f.plan} onChange={(e) => setF({ ...f, plan: e.target.value })}>
          <option value="contado">De contado</option><option value="mitades">En 2 partes (50 % y 50 %)</option><option value="otro">Otro acuerdo</option>
        </select>
      </label>
      {f.plan === 'mitades' && (
        <div className="v-dos">
          <label>Primer pago ({$(venta / 2)})<input type="date" value={f.fecha1} onChange={(e) => setF({ ...f, fecha1: e.target.value })} required /></label>
          <label>Segundo pago ({$(venta / 2)})<input type="date" value={f.fecha2} onChange={(e) => setF({ ...f, fecha2: e.target.value })} required /></label>
        </div>
      )}
      <label>Notas (opcional)<input value={f.notas} onChange={(e) => setF({ ...f, notas: e.target.value })} /></label>
      {error && <div className="v-aviso err" role="alert">{error}</div>}
      <button className="v-btn grande" type="submit" disabled={enviando}>{enviando ? 'Enviando…' : 'Enviar pedido'}</button>
      <p className="v-nota">Tu pedido queda pendiente hasta que la perfumería lo apruebe. Después podrás anotar aquí lo que te vayan pagando.</p>
    </form>
  )
}

function MisPedidos({ token, pedidos, resumen, recargar, manejar }) {
  return (
    <>
      <div className="v-resumen">
        <div className="gan"><small>Ya ganaste</small><b>{$(resumen.ganado)}</b><em>primero se cubre la perfumería</em></div>
        <div><small>Clientes te deben</small><b>{$(resumen.porCobrar)}</b></div>
        <div><small>Debes a la perfumería</small><b>{$(resumen.debo)}</b><em>lo cobrado hasta su consigna</em></div>
      </div>
      {!pedidos.length && <p className="v-vacio">Aún no has enviado pedidos.</p>}
      {pedidos.map((p) => <Pedido key={p.id} p={p} token={token} recargar={recargar} manejar={manejar} />)}
    </>
  )
}

function Pedido({ p, token, recargar, manejar }) {
  const [abierto, setAbierto] = useState(p.estado === 'aprobado' && num(p.falta) > 0)
  const [c, setC] = useState({ quien: p.cliente, monto: '', fecha: hoy(), nota: '' })
  const [error, setError] = useState('')
  const [e, est] = ESTADO[p.estado] || ['', p.estado]
  const progreso = num(p.total_venta) > 0 ? Math.min(100, (num(p.cobrado) / num(p.total_venta)) * 100) : 0
  const puedeCobrar = (p.estado === 'aprobado' || p.estado === 'entregado') && num(p.falta) > 0.005

  const llamar = async (fn, args) => {
    setError('')
    const { error: err } = await supabase.rpc(fn, { p_token: token, ...args })
    if (err) { if (/sesión venció/i.test(err.message)) return manejar(err); return setError(err.message) }
    recargar()
  }
  const anotar = async (ev) => {
    ev.preventDefault()
    await llamar('vend_registrar_cobro', { p_pedido_id: p.id, p_fecha: c.fecha, p_monto: num(c.monto), p_quien: c.quien, p_nota: c.nota })
    setC({ ...c, monto: '', nota: '' })
  }

  return (
    <article className={'v-pedido ' + e}>
      <button className="v-pedido-cab" onClick={() => setAbierto(!abierto)} aria-expanded={abierto}>
        <span><b>{p.cliente}</b><small>#{p.id} · {String(p.creado).slice(0, 10)}</small></span>
        <span className="v-chip">{est}</span>
        <b>{$(p.total_venta)}</b>
      </button>
      {abierto && (
        <div className="v-pedido-cuerpo">
          <ul className="v-items">{p.items.map((i, k) => <li key={k}>{i.perfume} · {i.unidades} u · vendes a {$(i.precio_venta)} <small>(consigna {$(i.consigna)})</small></li>)}</ul>
          <div className="v-totales">
            <div><small>Venta</small><b>{$(p.total_venta)}</b></div>
            <div><small>Perfumería</small><b>{$(p.total_consigna)}</b></div>
            <div className="gan"><small>Tu ganancia</small><b>{$(p.ganancia)}</b><em>ya ganada {$(p.ganada)}</em></div>
          </div>
          {p.estado === 'rechazado' && <div className="v-aviso err">Pedido rechazado{p.nota_admin ? `: ${p.nota_admin}` : '.'}</div>}
          {p.estado === 'pendiente' && <p className="v-nota">Esperando que la perfumería lo apruebe.</p>}
          {(p.estado === 'aprobado' || p.estado === 'entregado') && (
            <>
              <div className="v-barra" role="progressbar" aria-valuenow={Math.round(progreso)} aria-valuemin="0" aria-valuemax="100"><div style={{ width: progreso + '%' }} /></div>
              <div className="v-cobro-res">
                <span>Cobrado <b>{$(p.cobrado)}</b></span><span>Falta <b>{$(p.falta)}</b></span>
                {p.plan === 'mitades' && <span>Pagos: {corta(p.fecha1)} y {corta(p.fecha2)}</span>}
              </div>
              <div className="v-cobro-res"><span>Debes a la perfumería <b>{$(p.debe_perfumeria)}</b></span><span>Ya entregado <b>{$(p.pagado_perfumeria)}</b></span></div>
              {p.cobros.length > 0 && (
                <ul className="v-cobros">
                  {p.cobros.map((x) => (
                    <li key={x.id}><span>{corta(x.fecha)} · {x.quien}{x.nota ? ` · ${x.nota}` : ''}</span><b>{$(x.monto)}</b>
                      {x.borrable && <button className="v-x" onClick={() => llamar('vend_borrar_cobro', { p_cobro_id: x.id })} aria-label="Borrar cobro">🗑️</button>}</li>
                  ))}
                </ul>
              )}
              {puedeCobrar && (
                <form onSubmit={anotar} className="v-cobrar">
                  <b>Anotar un cobro</b>
                  <label>¿Quién pagó?<input value={c.quien} onChange={(e2) => setC({ ...c, quien: e2.target.value })} required /></label>
                  <div className="v-dos">
                    <label>Monto $<input type="number" step="0.01" min="0.01" max={num(p.falta).toFixed(2)} inputMode="decimal" value={c.monto} onChange={(e2) => setC({ ...c, monto: e2.target.value })} required /></label>
                    <label>Fecha<input type="date" value={c.fecha} max={hoy()} onChange={(e2) => setC({ ...c, fecha: e2.target.value })} required /></label>
                  </div>
                  <button type="button" className="v-link" onClick={() => setC({ ...c, monto: num(p.falta).toFixed(2) })}>Poner todo lo que falta ({$(p.falta)})</button>
                  <button className="v-btn" type="submit">Guardar cobro</button>
                </form>
              )}
              {p.estado === 'aprobado' && <button className="v-btn sec" onClick={() => llamar('vend_marcar_entregado', { p_pedido_id: p.id })}>Marcar como entregado al cliente</button>}
            </>
          )}
          {error && <div className="v-aviso err" role="alert">{error}</div>}
        </div>
      )}
    </article>
  )
}
