import React, { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { normNombre, num } from '../lib.js'
import Botella, { tonoDe, TONOS } from './Botella.jsx'
import './tienda.css'

const $ = (v) => '$' + (Number.isInteger(num(v)) ? String(num(v)) : num(v).toFixed(2).replace('.', ','))
const Bs = (v, tasa) => 'Bs ' + Math.round(num(v) * num(tasa)).toLocaleString('es-VE')
const digitos = (s) => String(s || '').replace(/\D/g, '')
const guardado = (k, def) => { try { return JSON.parse(localStorage.getItem(k)) ?? def } catch { return def } }
const guardar = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* sin almacenamiento */ } }

export default function Tienda() {
  const [cat, setCat] = useState(null)
  const [info, setInfo] = useState(null)
  const [error, setError] = useState('')
  const [tab, setTab] = useState('detal')
  const [q, setQ] = useState('')
  const [solo, setSolo] = useState('todos')
  const [carro, setCarro] = useState(() => guardado('tienda-carro', {}))
  const [cajon, setCajon] = useState(false)
  const [agendar, setAgendar] = useState(null)
  const [listo, setListo] = useState(null)
  const [aviso, setAviso] = useState('')

  const cargar = async () => {
    const [c, i] = await Promise.all([supabase.rpc('tienda_catalogo'), supabase.rpc('tienda_info')])
    if (c.error || i.error) return setError('No pudimos cargar el catálogo. Intenta de nuevo en un momento.')
    setCat(c.data || []); setInfo(i.data); setError('')
  }
  useEffect(() => { cargar(); const t = setInterval(cargar, 90000); return () => clearInterval(t) }, [])
  useEffect(() => { if (info?.nombre) document.title = info.nombre + ' · Perfumes' }, [info])
  useEffect(() => { guardar('tienda-carro', carro) }, [carro])
  useEffect(() => { if (!aviso) return; const t = setTimeout(() => setAviso(''), 3500); return () => clearTimeout(t) }, [aviso])

  const umbral = info?.umbral_mayor || 12
  const tasa = info?.tasa
  const porId = useMemo(() => Object.fromEntries((cat || []).map((p) => [p.id, p])), [cat])

  // Carrito: quita lo que ya no existe o se agotó y recorta a lo disponible
  const lineas = useMemo(() => Object.entries(carro).map(([id, u]) => {
    const p = porId[id]; if (!p || p.stock < 1) return null
    return { p, u: Math.min(u, p.stock) }
  }).filter(Boolean), [carro, porId])
  const unidades = lineas.reduce((a, l) => a + l.u, 0)
  const mayor = unidades >= umbral
  const precioDe = (p) => num(mayor ? p.precio_mayor : p.precio_detal)
  const total = lineas.reduce((a, l) => a + precioDe(l.p) * l.u, 0)
  const totalDetal = lineas.reduce((a, l) => a + num(l.p.precio_detal) * l.u, 0)
  const ahorro = mayor ? totalDetal - total : 0

  const cambiar = (id, delta) => setCarro((c) => {
    const p = porId[id]; const nuevo = Math.max(0, Math.min((c[id] || 0) + delta, p?.stock || 0))
    const n = { ...c }; if (nuevo) n[id] = nuevo; else delete n[id]; return n
  })

  const visibles = useMemo(() => (cat || [])
    .filter((p) => (!q || normNombre(p.nombre).includes(normNombre(q))) && (solo === 'todos' || (solo === 'disp' ? p.stock > 0 : p.stock === 0)))
    .sort((a, b) => (b.stock > 0) - (a.stock > 0) || a.nombre.localeCompare(b.nombre, 'es')), [cat, q, solo])
  const nDisp = (cat || []).filter((p) => p.stock > 0).length

  if (error && !cat) return <div className="t-estado"><p>{error}</p><button className="t-btn" onClick={cargar}>Reintentar</button></div>
  if (!cat || !info) return <div className="t-estado"><p>Cargando perfumes…</p></div>

  return (
    <div className="tienda">
      <header className="t-top">
        <a className="t-nombre" href="#inicio">{info.nombre}</a>
        <nav className="t-nav" aria-label="Secciones">
          <a href="#catalogo">Catálogo</a><a href="#pagos">Cómo pagar</a>
        </nav>
        <button className="t-carrito" onClick={() => setCajon(true)} aria-label={`Abrir carrito, ${unidades} perfumes`}>
          Carrito{unidades > 0 && <b>{unidades}</b>}
        </button>
      </header>

      <section className="t-hero" id="inicio">
        <div className="t-hero-texto">
          <h1>{info.nombre}</h1>
          <p>{info.mensaje}</p>
          <ul className="t-tasas" aria-label="Tasas del día">
            {tasa ? (<>
              <li><span>Dólar BCV</span><b>Bs {num(tasa.bcv).toLocaleString('es-VE')}</b></li>
              <li><span>Dólar Binance</span><b>Bs {num(tasa.binance).toLocaleString('es-VE')}</b></li>
            </>) : <li><span>Tasas del día</span><b>por actualizar</b></li>}
          </ul>
        </div>
        <div className="t-hero-frascos" aria-hidden="true">
          {Object.values(TONOS).slice(0, 5).map((t, i) => <Botella key={i} nombre={'x' + i} tono={t} />)}
        </div>
      </section>

      <section className="t-controles" id="catalogo">
        <div className="t-tabs" role="tablist">
          <button role="tab" aria-selected={tab === 'detal'} className={tab === 'detal' ? 'on' : ''} onClick={() => setTab('detal')}>Al detal</button>
          <button role="tab" aria-selected={tab === 'mayor'} className={tab === 'mayor' ? 'on' : ''} onClick={() => setTab('mayor')}>Al mayor</button>
        </div>
        <input className="t-buscar" type="search" placeholder="Buscar un perfume" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Buscar un perfume" />
        <div className="t-filtros">
          {[['todos', 'Todos'], ['disp', `Disponibles (${nDisp})`], ['agot', 'Agotados']].map(([k, n]) => (
            <button key={k} className={solo === k ? 'on' : ''} onClick={() => setSolo(k)}>{n}</button>
          ))}
        </div>
      </section>

      {tab === 'mayor' && (
        <aside className="t-mayor-info">
          <b>Precio al mayor desde {umbral} perfumes.</b> Puedes mezclar los que quieras: al llegar a {umbral} en el carrito, todo tu pedido pasa al precio al mayor.
        </aside>
      )}

      <main className="t-grid">
        {!visibles.length && <p className="t-vacio">No encontramos perfumes con ese nombre.</p>}
        {visibles.map((p) => {
          const agot = p.stock < 1
          const tono = tonoDe(p.nombre)
          const enCarro = carro[p.id] || 0
          const precio = tab === 'mayor' ? num(p.precio_mayor) : num(p.precio_detal)
          return (
            <article key={p.id} className={'t-card' + (agot ? ' agotado' : '')}>
              <div className="t-foto" style={{ background: tono.fondo }}>
                {p.foto_url ? <img src={p.foto_url} alt={p.nombre} loading="lazy" /> : <Botella nombre={p.nombre} tono={tono} />}
                {agot && <span className="t-sello">Agotado</span>}
                {!agot && p.stock <= 2 && <span className="t-sello poco">{p.stock === 1 ? 'Última unidad' : `Quedan ${p.stock}`}</span>}
              </div>
              <div className="t-info">
                <h3>{p.nombre}</h3>
                <div className="t-precio">
                  <b>{$(precio)}</b>
                  {tasa && <small>{Bs(precio, tasa.binance)}</small>}
                </div>
                {tab === 'mayor' && num(p.precio_mayor) < num(p.precio_detal) && <small className="t-nota">Al detal {$(p.precio_detal)} · el mayor aplica desde {umbral} perfumes</small>}
                {agot
                  ? <button className="t-btn sec" onClick={() => setAgendar(p)}>Agendar pedido</button>
                  : enCarro
                    ? (
                      <div className="t-paso" role="group" aria-label={`Cantidad de ${p.nombre}`}>
                        <button onClick={() => cambiar(p.id, -1)} aria-label="Quitar uno">−</button>
                        <output>{enCarro}</output>
                        <button onClick={() => cambiar(p.id, 1)} disabled={enCarro >= p.stock} aria-label="Agregar uno">+</button>
                      </div>
                    )
                    : <button className="t-btn" onClick={() => cambiar(p.id, 1)}>Agregar al carrito</button>}
              </div>
            </article>
          )
        })}
      </main>

      <section className="t-pagos" id="pagos">
        <h2>Cómo pagar</h2>
        <p className="t-sub">Los precios están en dólares. Si pagas en bolívares, se calcula con la tasa del día{tasa ? ` (Binance Bs ${num(tasa.binance).toLocaleString('es-VE')})` : ''}.</p>
        <div className="t-metodos">
          {(info.metodos || []).map((m, i) => (
            <div key={i} className="t-metodo"><h3>{m.titulo}</h3><p>{m.detalle}</p></div>
          ))}
        </div>
        <ol className="t-pasos">
          <li>Elige tus perfumes y pulsa <b>Agregar al carrito</b>.</li>
          <li>Escribe tu nombre y teléfono y pulsa <b>Enviar pedido por WhatsApp</b>.</li>
          <li>Te confirmamos y coordinamos el pago y la entrega.</li>
        </ol>
      </section>

      <footer className="t-pie">
        <p>{info.nombre} · Precios sujetos a cambio y a disponibilidad.</p>
      </footer>

      {unidades > 0 && !cajon && (
        <button className="t-barra-carro" onClick={() => setCajon(true)}>
          <span>{unidades} {unidades === 1 ? 'perfume' : 'perfumes'}{mayor ? ' · precio al mayor' : ''}</span><b>Ver carrito · {$(total)}</b>
        </button>
      )}

      {cajon && <Cajon onCerrar={() => setCajon(false)} {...{ lineas, unidades, umbral, mayor, total, ahorro, tasa, info, precioDe, cambiar, setCarro, cargar, setListo }} />}
      {agendar && <Agendar p={agendar} onCerrar={() => setAgendar(null)} onListo={(m) => { setAgendar(null); setAviso(m) }} />}
      {listo && <Listo r={listo} info={info} onCerrar={() => setListo(null)} />}
      {aviso && <div className="t-toast" role="status">{aviso}</div>}
    </div>
  )
}

function Cajon({ onCerrar, lineas, unidades, umbral, mayor, total, ahorro, tasa, info, precioDe, cambiar, setCarro, cargar, setListo }) {
  const [f, setF] = useState(() => ({ nombre: '', telefono: '', notas: '', metodo: '', ...guardado('tienda-datos', {}) }))
  const [err, setErr] = useState('')
  const [enviando, setEnviando] = useState(false)
  const faltan = Math.max(umbral - unidades, 0)
  const metodos = info.metodos || []

  useEffect(() => {
    const k = (e) => e.key === 'Escape' && onCerrar()
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k)
  }, [onCerrar])

  const enviar = async (e) => {
    e.preventDefault(); setErr('')
    setEnviando(true)
    const { data, error } = await supabase.rpc('tienda_crear_pedido', {
      p_cliente: f.nombre, p_telefono: f.telefono, p_notas: f.notas, p_metodo: f.metodo,
      p_items: lineas.map((l) => ({ perfume_id: l.p.id, unidades: l.u })),
    })
    setEnviando(false)
    if (error) { setErr(error.message); cargar(); return }
    guardar('tienda-datos', { nombre: f.nombre, telefono: f.telefono })
    const detalle = lineas.map((l) => ({ nombre: l.p.nombre, u: l.u, precio: precioDe(l.p) }))
    setListo({ ...data, detalle, cliente: f.nombre, telefono: f.telefono, metodo: f.metodo, notas: f.notas })
    setCarro({}); cargar(); onCerrar()
  }

  return (
    <div className="t-cortina" onClick={onCerrar}>
      <aside className="t-cajon" role="dialog" aria-modal="true" aria-label="Tu carrito" onClick={(e) => e.stopPropagation()}>
        <header><h2>Tu carrito</h2><button onClick={onCerrar} aria-label="Cerrar">Cerrar</button></header>
        {!lineas.length ? <p className="t-vacio">Todavía no has agregado perfumes.</p> : (
          <form onSubmit={enviar}>
            <ul className="t-lineas">
              {lineas.map(({ p, u }) => (
                <li key={p.id}>
                  <div><b>{p.nombre}</b><small>{$(precioDe(p))} c/u</small></div>
                  <div className="t-paso chico">
                    <button type="button" onClick={() => cambiar(p.id, -1)} aria-label="Quitar uno">−</button>
                    <output>{u}</output>
                    <button type="button" onClick={() => cambiar(p.id, 1)} disabled={u >= p.stock} aria-label="Agregar uno">+</button>
                  </div>
                  <span className="t-sub-linea">{$(precioDe(p) * u)}</span>
                </li>
              ))}
            </ul>

            <div className={'t-mayorbar' + (mayor ? ' ok' : '')}>
              {mayor
                ? <p><b>Precio al mayor aplicado.</b>{ahorro > 0 ? ` Te ahorras ${$(ahorro)}.` : ''}</p>
                : <p>Agrega <b>{faltan}</b> {faltan === 1 ? 'perfume más' : 'perfumes más'} y todo tu pedido pasa al precio al mayor.</p>}
              <div className="t-barra"><i style={{ width: Math.min(100, (unidades / umbral) * 100) + '%' }} /></div>
            </div>

            <div className="t-total"><span>Total</span><div><b>{$(total)}</b>{tasa && <small>{Bs(total, tasa.binance)} a tasa Binance</small>}</div></div>

            <label className="t-campo"><span>Tu nombre</span><input value={f.nombre} onChange={(e) => setF({ ...f, nombre: e.target.value })} required autoComplete="name" /></label>
            <label className="t-campo"><span>Tu teléfono (WhatsApp)</span><input value={f.telefono} onChange={(e) => setF({ ...f, telefono: e.target.value })} required inputMode="tel" autoComplete="tel" placeholder="0414-1234567" /></label>
            {metodos.length > 0 && (
              <label className="t-campo"><span>¿Cómo vas a pagar?</span>
                <select value={f.metodo} onChange={(e) => setF({ ...f, metodo: e.target.value })} required>
                  <option value="">Elige una opción</option>
                  {metodos.map((m, i) => <option key={i}>{m.titulo}</option>)}
                </select>
              </label>
            )}
            <label className="t-campo"><span>Notas (opcional)</span><input value={f.notas} onChange={(e) => setF({ ...f, notas: e.target.value })} placeholder="Zona de entrega, regalo, etc." /></label>
            {err && <p className="t-error" role="alert">{err}</p>}
            <button className="t-btn grande" type="submit" disabled={enviando}>{enviando ? 'Enviando…' : 'Enviar pedido por WhatsApp'}</button>
            <p className="t-ayuda">Apartamos tus perfumes al enviar. Te confirmamos el pago y la entrega por WhatsApp.</p>
          </form>
        )}
      </aside>
    </div>
  )
}

function Agendar({ p, onCerrar, onListo }) {
  const [f, setF] = useState(() => ({ nombre: '', telefono: '', unidades: 1, ...guardado('tienda-datos', {}) }))
  const [err, setErr] = useState('')
  const enviar = async (e) => {
    e.preventDefault(); setErr('')
    const { error } = await supabase.rpc('tienda_agendar', { p_perfume_id: p.id, p_cliente: f.nombre, p_telefono: f.telefono, p_unidades: Number(f.unidades) })
    if (error) return setErr(error.message)
    guardar('tienda-datos', { nombre: f.nombre, telefono: f.telefono })
    onListo(`Listo. Te escribimos cuando llegue ${p.nombre}.`)
  }
  return (
    <div className="t-cortina centro" onClick={onCerrar}>
      <form className="t-modal" onSubmit={enviar} onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={`Agendar ${p.nombre}`}>
        <h2>Agendar {p.nombre}</h2>
        <p className="t-ayuda">Ahora está agotado. Déjanos tus datos y te avisamos por WhatsApp apenas lo traigamos. No tiene costo ni te compromete a comprar.</p>
        <label className="t-campo"><span>Tu nombre</span><input value={f.nombre} onChange={(e) => setF({ ...f, nombre: e.target.value })} required autoComplete="name" /></label>
        <label className="t-campo"><span>Tu teléfono (WhatsApp)</span><input value={f.telefono} onChange={(e) => setF({ ...f, telefono: e.target.value })} required inputMode="tel" autoComplete="tel" placeholder="0414-1234567" /></label>
        <label className="t-campo"><span>¿Cuántos quieres?</span><input type="number" min="1" max="60" value={f.unidades} onChange={(e) => setF({ ...f, unidades: e.target.value })} required /></label>
        {err && <p className="t-error" role="alert">{err}</p>}
        <div className="t-acciones"><button type="button" className="t-btn sec" onClick={onCerrar}>Cancelar</button><button className="t-btn" type="submit">Agendar pedido</button></div>
      </form>
    </div>
  )
}

function Listo({ r, info, onCerrar }) {
  const lineas = r.detalle.map((d) => `• ${d.u} × ${d.nombre} (${$(d.precio)} c/u)`).join('\n')
  const texto = `Hola, quiero confirmar mi pedido ${r.codigo}:\n${lineas}\n\nTotal: ${$(r.total)}${r.mayor ? ' (precio al mayor)' : ''}` +
    (r.metodo ? `\nPago: ${r.metodo}` : '') + `\nNombre: ${r.cliente}\nTeléfono: ${r.telefono}` + (r.notas ? `\nNotas: ${r.notas}` : '')
  const numero = digitos(info.whatsapp)
  const enlace = numero ? `https://wa.me/${numero}?text=${encodeURIComponent(texto)}` : null
  return (
    <div className="t-cortina centro">
      <div className="t-modal" role="dialog" aria-modal="true" aria-label="Pedido recibido">
        <h2>Pedido {r.codigo} recibido</h2>
        <p>Apartamos tus perfumes por <b>{$(r.total)}</b>. Falta un paso: <b>envíanos el pedido por WhatsApp</b> para que lo confirmemos y coordinemos el pago.</p>
        {enlace
          ? <a className="t-btn grande" href={enlace} target="_blank" rel="noreferrer">Enviar pedido por WhatsApp</a>
          : <p className="t-ayuda">Te escribiremos al {r.telefono} para confirmar tu pedido.</p>}
        <button className="t-btn sec" onClick={onCerrar}>Seguir viendo perfumes</button>
      </div>
    </div>
  )
}
