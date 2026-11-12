import React, { useEffect, useMemo, useRef, useState } from 'react'
import { rpc, esDemo } from './api.js'
import { normNombre, num } from '../lib.js'
import Botella, { tonoDe } from './Botella.jsx'
import './tienda.css'

const WHATSAPP_POR_DEFECTO = '584241735215'
const INSTAGRAM_POR_DEFECTO = 'https://www.instagram.com/motosaperfumes/?hl=es'
const FAMILIAS = [
  ['Dulce', 'Vainilla, frutas y caramelo'], ['Floral', 'Rosa, jazmín y peonía'], ['Fresco', 'Cítricos y notas marinas'],
  ['Amaderado', 'Sándalo, cedro y cuero'], ['Ámbar y especiado', 'Cálido, con canela y pimienta'], ['Gourmand', 'Café, cacao y praliné'],
]
const OCASIONES = ['Día a día', 'Salidas', 'Citas', 'Noche']
const RANGOS = [['', 'Cualquier precio'], ['a', 'Hasta $30'], ['b', '$31 a $36'], ['c', 'Más de $36']]
const enRango = (r, v) => !r || (v != null && (r === 'a' ? v <= 30 : r === 'b' ? v > 30 && v <= 36 : v > 36))
const tieneOcasion = (p, o) => String(p.ocasion || '').split(',').map((x) => x.trim()).includes(o)
// Notas: si vienen como "Salida: … · Corazón: … · Fondo: …" se muestran por niveles; si no, como texto
const parseNotas = (t) => {
  if (!t) return null
  const partes = t.split(/\s*[·|]\s*/).map((x) => x.match(/^(salida|coraz[oó]n|fondo)\s*:\s*(.+)$/i)).filter(Boolean)
  return partes.length >= 2 ? partes.map((m) => [m[1][0].toUpperCase() + m[1].slice(1).toLowerCase(), m[2]]) : null
}
const $ = (v) => '$' + (Number.isInteger(num(v)) ? String(num(v)) : num(v).toFixed(2).replace('.', ','))
const Bs = (v, tasa) => 'Bs ' + Math.round(num(v) * num(tasa)).toLocaleString('es-VE')
const digitos = (s) => String(s || '').replace(/\D/g, '')
const guardado = (k, def) => { try { return JSON.parse(localStorage.getItem(k)) ?? def } catch { return def } }
const guardar = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)) } catch { /* sin almacenamiento */ } }

const Icono = ({ d, ...p }) => (
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...p}>{d}</svg>
)
const iBolsa = <><path d="M5 8h14l-1 12H6L5 8z" /><path d="M9 8V6a3 3 0 016 0v2" /></>
const iFlechaIzq = <path d="M15 5l-7 7 7 7" />
const iFlechaDer = <path d="M9 5l7 7-7 7" />
const iFlechaLarga = <path d="M6 12h12M13 7l5 5-5 5" />

export default function Tienda() {
  const [cat, setCat] = useState(null)
  const [info, setInfo] = useState(null)
  const [error, setError] = useState('')
  const [tab, setTab] = useState('detal')
  const [q, setQ] = useState('')
  const [solo, setSolo] = useState('todos')
  const [genero, setGenero] = useState('todos')
  const [marca, setMarca] = useState('')
  const [ver, setVer] = useState(null)
  const [carro, setCarro] = useState(() => guardado('tienda-carro', {}))
  const [cajon, setCajon] = useState(false)
  const [agendar, setAgendar] = useState(null)
  const [listo, setListo] = useState(null)
  const [aviso, setAviso] = useState('')
  const [top, setTop] = useState(0)
  const [familia, setFamilia] = useState('')
  const [ocasion, setOcasion] = useState('')
  const [rango, setRango] = useState('')
  const [soloFavs, setSoloFavs] = useState(false)
  const [favs, setFavs] = useState(() => guardado('tienda-favs', []))
  const [quiz, setQuiz] = useState(false)

  const cargar = async () => {
    const [c, i] = await Promise.all([rpc('tienda_catalogo'), rpc('tienda_info')])
    if (c.error || i.error) return setError('No pudimos cargar el catálogo. Intenta de nuevo en un momento.')
    setCat(c.data || []); setInfo(i.data); setError('')
  }
  // La tasa y los precios se leen siempre de la base de datos: se refrescan cada minuto y al volver a la pestaña
  useEffect(() => {
    cargar()
    const t = setInterval(cargar, 60000)
    const visible = () => { if (document.visibilityState === 'visible') cargar() }
    document.addEventListener('visibilitychange', visible)
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', visible) }
  }, [])
  useEffect(() => { if (info?.nombre) document.title = info.nombre + ' · Perfumes' }, [info])
  useEffect(() => { guardar('tienda-carro', carro) }, [carro])
  useEffect(() => { guardar('tienda-favs', favs) }, [favs])
  const alternarFav = (id) => setFavs((f) => (f.includes(id) ? f.filter((x) => x !== id) : [...f, id]))
  const verFamilia = (f) => { setFamilia(f); setTab('detal'); setTimeout(() => document.getElementById('catalogo')?.scrollIntoView({ behavior: 'smooth' }), 50) }
  useEffect(() => { if (!aviso) return; const t = setTimeout(() => setAviso(''), 3500); return () => clearTimeout(t) }, [aviso])

  const umbral = info?.umbral_mayor || 12
  // Link compartible de un perfume: ?p=ID abre su ficha
  const abierta = useRef(false)
  useEffect(() => {
    if (!cat || abierta.current) return
    abierta.current = true
    const id = new URLSearchParams(window.location.search).get('p')
    const p = id && cat.find((x) => String(x.id) === id)
    if (p) setVer(p)
  }, [cat])
  const abrirFicha = (p) => { setVer(p); try { const u = new URL(window.location.href); u.searchParams.set('p', p.id); window.history.replaceState(null, '', u) } catch { /* sin historial */ } }
  const cerrarFicha = () => { setVer(null); try { const u = new URL(window.location.href); u.searchParams.delete('p'); window.history.replaceState(null, '', u) } catch { /* sin historial */ } }
  const tasa = info?.tasa
  const porId = useMemo(() => Object.fromEntries((cat || []).map((p) => [p.id, p])), [cat])

  // Carrito: quita lo que ya no existe o se agotó y recorta a lo disponible
  const lineas = useMemo(() => Object.entries(carro).map(([id, u]) => {
    const p = porId[id]; if (!p || p.stock < 1 || p.precio_detal == null) return null
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
    .filter((p) => (!q || normNombre(p.nombre + ' ' + (p.marca || '')).includes(normNombre(q))) && (genero === 'todos' || p.genero === genero) && (!marca || p.marca === marca) && (!familia || p.familia === familia) && (!ocasion || tieneOcasion(p, ocasion)) && enRango(rango, p.precio_detal == null ? null : num(p.precio_detal)) && (!soloFavs || favs.includes(p.id)) && (solo === 'todos' || (solo === 'disp' ? p.stock > 0 && p.precio_detal != null : p.stock === 0 || p.precio_detal == null)))
    , [cat, q, solo, genero, marca, familia, ocasion, rango, soloFavs, favs])
  const marcas = useMemo(() => [...new Set((cat || []).map((p) => p.marca).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'es')), [cat])
  const hayGenero = (cat || []).some((p) => p.genero)
  const hayPerfil = (cat || []).some((p) => p.familia)
  const nuevos = useMemo(() => (cat || []).filter((p) => p.es_nuevo && p.stock > 0 && p.precio_detal != null).slice(0, 8), [cat])
  const masVendidos = useMemo(() => new Set((cat || []).filter((p) => p.vendidos > 0 && p.stock > 0).sort((a, b) => b.vendidos - a.vendidos).slice(0, 3).map((p) => p.id)), [cat])
  const hayFiltros = genero !== 'todos' || marca || familia || ocasion || rango || soloFavs
  const limpiarFiltros = () => { setGenero('todos'); setMarca(''); setFamilia(''); setOcasion(''); setRango(''); setSoloFavs(false) }
  const nDisp = (cat || []).filter((p) => p.stock > 0 && p.precio_detal != null).length

  // Top perfumes: los más vendidos que todavía tienen stock
  const masPedidos = useMemo(() => (cat || [])
    .filter((p) => p.stock > 0 && p.vendidos > 0 && p.precio_detal != null)
    .sort((a, b) => b.vendidos - a.vendidos || a.nombre.localeCompare(b.nombre, 'es')).slice(0, 3), [cat])

  if (error && !cat) return <div className="t-estado"><p>{error}</p><button className="t-btn" onClick={cargar}>Reintentar</button></div>
  if (!cat || !info) return <div className="t-estado"><p>Cargando perfumes…</p></div>

  const destacado = masPedidos[Math.min(top, masPedidos.length - 1)]

  return (
    <div className="tienda">
      <div className="t-tasas-barra">
        <div className="t-ancho">
          <div className="t-tasas" aria-label="Tasas del día">
            {tasa ? (<>
              <span>Tasa BCV Euro <b>Bs {num(tasa.euro).toLocaleString('es-VE')}</b></span>
            </>) : <span>Tasas del día <b>por actualizar</b></span>}
          </div>
          <span className="t-aviso-pago">Paga en dólares, bolívares o Binance</span>
        </div>
      </div>

      <header className="t-top">
        <div className="t-ancho t-top-fila">
          <a className="t-marca" href="#inicio" aria-label={info.nombre}><img src="/marca/logo-oro.png" alt={info.nombre} /></a>
          <nav className="t-nav" aria-label="Secciones">
            <a href="#catalogo">Perfumes</a>
            <button type="button" className="t-nav-btn" onClick={() => setQuiz(true)}>Encuentra tu perfume</button>
            <a href="#mayor">Al mayor</a>
            <a href="#pagos">Cómo pagar</a>
          </nav>
          <button className="t-carrito" onClick={() => setCajon(true)} aria-label={`Abrir carrito, ${unidades} perfumes`}>
            <Icono d={iBolsa} />
            {unidades > 0 && <b>{unidades}</b>}
          </button>
        </div>
      </header>

      <Hero info={info} onQuiz={() => setQuiz(true)} />

      <section className="t-confianza" aria-label="Cómo comprar">
        <div className="t-ancho t-confianza-fila">
          <div><Icono d={<path d="M4 5h16v11H9l-5 4V5z" />} /><span><b>Pedido por WhatsApp</b>Lo recibimos al instante</span></div>
          <div><Icono d={<><circle cx="12" cy="12" r="8" /><path d="M12 8v8M9.5 10.2c0-1 1-1.7 2.5-1.7s2.5.7 2.5 1.6c0 2-5 1.2-5 3.3 0 .9 1 1.7 2.5 1.7s2.5-.7 2.5-1.7" /></>} /><span><b>Paga en $, Bs o Binance</b>Bolívares a tasa BCV Euro</span></div>
          <div><Icono d={<><path d="M3 8l9-4 9 4-9 4-9-4z" /><path d="M3 8v8l9 4 9-4V8" /></>} /><span><b>Al mayor con {umbral} perfumes</b>Pueden ser todos diferentes</span></div>
          <div><Icono d={<><rect x="4" y="5" width="16" height="15" rx="1" /><path d="M4 10h16M9 3v4M15 3v4" /></>} /><span><b>Agenda el que quieras</b>Te avisamos cuando llegue</span></div>
        </div>
      </section>

      <section className="t-quiz-banner">
        <div className="t-ancho t-quiz-fila">
          <div><h2>¿No sabes cuál elegir?</h2><p>Responde 3 preguntas y te recomendamos 3 perfumes.</p></div>
          <button type="button" className="t-btn dorado" onClick={() => setQuiz(true)}>Empezar el quiz</button>
        </div>
      </section>

      {hayPerfil && (
        <section className="t-familias" aria-labelledby="t-fam-h">
          <div className="t-ancho">
            <h2 id="t-fam-h">Elige por familia olfativa</h2>
            <div className="t-fam-grid">
              {FAMILIAS.map(([f, d]) => (
                <button type="button" key={f} className="t-fam" onClick={() => verFamilia(f)}><b>{f}</b><small>{d}</small></button>
              ))}
            </div>
          </div>
        </section>
      )}

      {nuevos.length > 0 && (
        <section className="t-nuevos" aria-labelledby="t-nue-h">
          <div className="t-ancho">
            <h2 id="t-nue-h">Llegó mercancía nueva</h2>
            <div className="t-nue-fila">
              {nuevos.map((p) => (
                <button type="button" key={p.id} className="t-nue" onClick={() => abrirFicha(p)}>
                  <span className="t-nue-foto" style={{ background: tonoDe(p.nombre).fondo }}>{p.foto_url ? <img src={p.foto_url} alt="" loading="lazy" /> : <Botella nombre={p.nombre} tono={tonoDe(p.nombre)} />}</span>
                  <small>{p.marca}</small><b>{p.nombre}</b>
                </button>
              ))}
            </div>
          </div>
        </section>
      )}

      <section className="t-catalogo" id="catalogo">
        <div className="t-ancho">
          <div className="t-cat-cabeza">
            <h2>Todos los perfumes</h2>
            <div className="t-tabs" role="tablist" aria-label="Tipo de precio">
              <button role="tab" aria-selected={tab === 'detal'} className={tab === 'detal' ? 'on' : ''} onClick={() => setTab('detal')}>Al detal</button>
              <button role="tab" aria-selected={tab === 'mayor'} className={tab === 'mayor' ? 'on' : ''} onClick={() => setTab('mayor')}>Al mayor</button>
            </div>
          </div>
          <div className="t-controles">
            <label className="t-buscar">
              <Icono d={<><circle cx="11" cy="11" r="7" /><path d="M20 20l-3.5-3.5" /></>} width="20" height="20" />
              <input type="search" placeholder="Busca un perfume" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Busca un perfume" />
            </label>
            <div className="t-filtros" role="group" aria-label="Disponibilidad">
              {[['todos', 'Todos'], ['disp', `Disponibles (${nDisp})`], ['agot', `Por agendar (${(cat || []).length - nDisp})`]].map(([k, n]) => (
                <button key={k} className={solo === k ? 'on' : ''} onClick={() => setSolo(k)}>{n}</button>
              ))}
            </div>
          </div>

          {(hayGenero || marcas.length > 1) && (
            <div className="t-controles t-controles2">
              {hayGenero && (
                <div className="t-filtros" role="group" aria-label="Género">
                  {[['todos', 'Para todos'], ['mujer', 'Mujer'], ['hombre', 'Hombre'], ['unisex', 'Unisex']].map(([k, n]) => (
                    <button key={k} className={genero === k ? 'on' : ''} aria-pressed={genero === k} onClick={() => setGenero(k)}>{n}</button>
                  ))}
                </div>
              )}
              {marcas.length > 1 && (
                <label className="t-marca-sel">
                  <span>Marca</span>
                  <select value={marca} onChange={(e) => setMarca(e.target.value)} aria-label="Filtrar por marca">
                    <option value="">Todas las marcas</option>
                    {marcas.map((m) => <option key={m} value={m}>{m}</option>)}
                  </select>
                </label>
              )}
              {hayFiltros && <button className="t-limpiar" onClick={limpiarFiltros}>Quitar filtros</button>}
            </div>
          )}
          {(hayPerfil || favs.length > 0) && (
            <div className="t-controles t-controles2">
              {hayPerfil && (
                <div className="t-filtros" role="group" aria-label="Familia olfativa">
                  {['', ...FAMILIAS.map((f) => f[0])].map((f) => (
                    <button key={f || 'todas'} className={familia === f ? 'on' : ''} aria-pressed={familia === f} onClick={() => setFamilia(f)}>{f || 'Todas las familias'}</button>
                  ))}
                </div>
              )}
              {hayPerfil && (
                <label className="t-marca-sel"><span>Ocasión</span>
                  <select value={ocasion} onChange={(e) => setOcasion(e.target.value)} aria-label="Filtrar por ocasión">
                    <option value="">Cualquiera</option>{OCASIONES.map((o) => <option key={o}>{o}</option>)}
                  </select>
                </label>
              )}
              <label className="t-marca-sel"><span>Precio</span>
                <select value={rango} onChange={(e) => setRango(e.target.value)} aria-label="Filtrar por precio">
                  {RANGOS.map(([k, n]) => <option key={k} value={k}>{n}</option>)}
                </select>
              </label>
              <button type="button" className={'t-fav-filtro' + (soloFavs ? ' on' : '')} aria-pressed={soloFavs} onClick={() => setSoloFavs(!soloFavs)}>♥ Favoritos ({favs.length})</button>
            </div>
          )}
          <p className="t-conteo" role="status">{visibles.length} {visibles.length === 1 ? 'perfume' : 'perfumes'}</p>

          {tab === 'mayor' && (
            <aside className="t-mayor-info">
              <b>El precio al mayor se desbloquea con {umbral} perfumes.</b> No tienen que ser iguales: pueden ser {umbral} perfumes diferentes. Al llegar a {umbral} en el carrito, todo tu pedido pasa al precio al mayor.
            </aside>
          )}

          <div className="t-grid">
            {!visibles.length && <p className="t-vacio">No encontramos perfumes con esos filtros.</p>}
            {visibles.map((p) => <Ficha key={p.id} {...{ p, tab, umbral, tasa, carro, cambiar, setAgendar, abrirFicha, fav: favs.includes(p.id), alternarFav, top: masVendidos.has(p.id) }} />)}
          </div>
        </div>
      </section>

      {destacado && (
        <section className="t-top-perfumes" aria-labelledby="t-top-h">
          <div className="t-ancho">
            <h2 id="t-top-h">Top perfumes <i>del mes</i></h2>
            <p className="t-top-sub">Los más pedidos por nuestros clientes, con stock limitado.</p>
            <div className="t-top-escena">
              <div className="t-vidrio">
                <h3>Precios</h3>
                <dl>
                  <div><dt>Al detal</dt><dd>{$(destacado.precio_detal)}</dd></div>
                  <div><dt>Al mayor ({umbral} perfumes)</dt><dd>{$(destacado.precio_mayor)}</dd></div>
                  {tasa && <div><dt>En bolívares</dt><dd>{Bs(destacado.precio_detal, tasa.euro)}</dd></div>}
                </dl>
              </div>
              <div className="t-top-centro">
                <div className="t-top-frasco">
                  <i aria-hidden="true" />
                  {destacado.foto_url
                    ? <img src={destacado.foto_url} alt={destacado.nombre} />
                    : <Botella nombre={destacado.nombre} tono={{ fondo: '#fff', liquido: '#1c2311' }} />}
                </div>
                <h3>{destacado.nombre}</h3>
                <button className="t-pildora" onClick={() => { cambiar(destacado.id, 1); setAviso('Agregado: ' + destacado.nombre) }}>
                  Agregar al carrito <span><Icono d={iFlechaLarga} width="18" height="18" /></span>
                </button>
                {masPedidos.length > 1 && (
                  <div className="t-top-lista" role="group" aria-label="Elegir perfume destacado">
                    {masPedidos.map((p, i) => (
                      <button key={p.id} className={i === top ? 'on' : ''} onClick={() => setTop(i)} aria-pressed={i === top}>{i + 1}. {p.nombre}</button>
                    ))}
                  </div>
                )}
              </div>
              <div className="t-vidrio">
                <h3>Disponibilidad</h3>
                <dl>
                  <div><dt>Stock</dt><dd>{destacado.stock === 1 ? 'Última unidad' : `Quedan ${destacado.stock}`}</dd></div>
                  <div><dt>Entrega</dt><dd>Coordinada</dd></div>
                  <div><dt>Pago</dt><dd>$ · Bs · Binance</dd></div>
                </dl>
              </div>
            </div>
          </div>
        </section>
      )}

      <section className="t-mayor" id="mayor">
        <div className="t-ancho">
          <div className="t-mayor-caja">
            <div>
              <h2>Con {umbral} perfumes, <i>precio al mayor</i></h2>
              <p>El precio al mayor se desbloquea con {umbral} perfumes en el carrito. No tienen que ser del mismo: pueden ser {umbral} perfumes diferentes, y todo tu pedido pasa al precio al mayor.</p>
            </div>
            <div className="t-mayor-progreso">
              <div className="t-mayor-fila"><span>Tu carrito</span><b>{Math.min(unidades, umbral)} de {umbral}</b></div>
              <div className="t-barra"><i style={{ width: Math.min(100, (unidades / umbral) * 100) + '%' }} /></div>
              <p>{mayor ? 'Precio al mayor aplicado a todo tu pedido.' : `Agrega ${umbral - unidades} ${umbral - unidades === 1 ? 'perfume más' : 'perfumes más'} y todo tu pedido pasa al precio al mayor.`}</p>
            </div>
          </div>
        </div>
      </section>

      <section className="t-pagos" id="pagos">
        <div className="t-ancho">
          <h2>Cómo pagar</h2>
          <div className="t-metodos">
            {(info.metodos || []).map((m, i) => (
              <div key={i} className="t-metodo"><h3>{m.titulo}</h3><p>{m.detalle}</p></div>
            ))}
            <div className="t-metodo t-metodo-tasas">
              <h3>Tasas de hoy</h3>
              {tasa ? (<>
                <p><span>BCV Euro</span><b>Bs {num(tasa.euro).toLocaleString('es-VE')}</b></p>
                <p className="t-nota-tasa">Pagas en bolívares: precio en $ × tasa BCV Euro del día.</p>
              </>) : <p>Por actualizar</p>}
            </div>
          </div>
        </div>
      </section>

      {info.felices?.length > 0 && (
        <section className="t-felices" aria-labelledby="t-fel-h">
          <div className="t-ancho">
            <h2 id="t-fel-h">Clientes felices</h2>
            <div className="t-fel-fila">
              {info.felices.map((f, i) => (
                <figure key={i} className="t-fel"><img src={f.url} alt={f.nombre ? `${f.nombre} con su perfume` : 'Cliente feliz'} loading="lazy" />
                  {(f.nombre || f.perfume) && <figcaption><b>{f.nombre}</b>{f.perfume && <small>Se llevó {f.perfume}</small>}</figcaption>}
                </figure>
              ))}
            </div>
          </div>
        </section>
      )}

      <section className="t-ig">
        <div className="t-ancho">
          <div className="t-ig-caja">
            <div>
              <h2>Síguenos en Instagram y obtén 5% de descuento</h2>
              <p>Síguenos en Instagram, enviamos el capture y obtén un 5% de descuento en tu pedido.</p>
              <small>Válido solo para nuevos clientes.</small>
            </div>
            <a className="t-btn bosque" href={info.instagram_url || INSTAGRAM_POR_DEFECTO} target="_blank" rel="noopener noreferrer">
              <Icono d={<><rect x="3" y="3" width="18" height="18" rx="5" /><circle cx="12" cy="12" r="4" /><circle cx="17.2" cy="6.8" r=".8" fill="currentColor" /></>} width="20" height="20" />Síguenos en Instagram
            </a>
          </div>
          <a className="t-cajas" href={info.cajas_url || `https://wa.me/${digitos(info.whatsapp) || WHATSAPP_POR_DEFECTO}?text=${encodeURIComponent('Hola, quiero iniciar mi propio negocio de perfumes. ¿Me cuentas cómo funcionan las cajas al mayor?')}`} target="_blank" rel="noopener noreferrer">
            <span><b>¿Quieres iniciar tu propio negocio de perfumes?</b><small>Compra cajas al mayor y revende con ganancia.</small></span>
            <i>Ver cajas al mayor</i>
          </a>
        </div>
      </section>

      <footer className="t-pie">
        <div className="t-ancho t-pie-fila">
          <div><img className="t-pie-logo" src="/marca/logo-oro.png" alt={info.nombre} /><p>Caracas, Venezuela</p></div>
          <div className="t-pie-enlaces"><a href="#catalogo">Perfumes</a><a href="#mayor">Al mayor</a><a href="#pagos">Cómo pagar</a><a href={info.instagram_url || INSTAGRAM_POR_DEFECTO} target="_blank" rel="noopener noreferrer">Instagram</a></div>
          <div><b>WhatsApp</b><p>{formatoTel(info.whatsapp || WHATSAPP_POR_DEFECTO)}</p></div>
        </div>
        <div className="t-ancho t-pie-nota">Precios sujetos a cambio y a disponibilidad.{esDemo ? ' · Vista previa con datos de ejemplo.' : ''}</div>
      </footer>

      {unidades > 0 && !cajon && (
        <button className="t-barra-carro" onClick={() => setCajon(true)}>
          <span className="t-barra-txt"><span>{mayor ? 'Precio al mayor aplicado' : `${unidades} de ${umbral} para precio al mayor`}</span><span className="t-barra"><i style={{ width: Math.min(100, (unidades / umbral) * 100) + '%' }} /></span></span><b>Ver carrito · {$(total)}</b>
        </button>
      )}

      {cajon && <Cajon onCerrar={() => setCajon(false)} {...{ lineas, unidades, umbral, mayor, total, ahorro, tasa, info, precioDe, cambiar, setCarro, cargar, setListo }} />}
      {ver && <Detalle p={cat.find((x) => x.id === ver.id) || ver} {...{ cat, tasa, umbral, carro, cambiar, setAgendar, info, setAviso, abrirFicha, favs, alternarFav }} onCerrar={cerrarFicha} />}
      {quiz && <Quiz cat={cat} tasa={tasa} umbral={umbral} onCerrar={() => setQuiz(false)} {...{ carro, cambiar, abrirFicha, setAviso }} />}
      {agendar && <Agendar p={agendar} onCerrar={() => setAgendar(null)} onListo={(m) => { setAgendar(null); setAviso(m) }} />}
      {listo && <Listo r={listo} info={info} onCerrar={() => setListo(null)} />}
      {aviso && <div className="t-toast" role="status">{aviso}</div>}
    </div>
  )
}

const GENERO = { mujer: 'Para ella', hombre: 'Para él', unisex: 'Unisex' }
const linkDe = (id) => `${window.location.origin}/p/${id}`

const formatoTel = (n) => {
  const d = digitos(n)
  return d.startsWith('58') && d.length === 12 ? `0${d.slice(2, 5)}-${d.slice(5)}` : n
}

// Carrusel de banners (hasta 4). Si todavía no hay banners subidos, muestra una portada con el nombre de la tienda.
function Hero({ info, onQuiz }) {
  const banners = (info.banners || []).slice(0, 4)
  const n = Math.max(banners.length, 1)
  const [i, setI] = useState(0)
  const [pausa, setPausa] = useState(false)
  const toque = useRef(null)
  const ir = (k) => setI(((k % n) + n) % n)
  useEffect(() => { if (i >= n) setI(0) }, [n, i])
  useEffect(() => {
    if (n < 2 || pausa) return
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return
    const t = setInterval(() => setI((x) => (x + 1) % n), 6000)
    return () => clearInterval(t)
  }, [n, pausa])

  return (
    <section id="inicio" className="t-hero" aria-roledescription="carrusel" aria-label="Promociones del mes"
      onMouseEnter={() => setPausa(true)} onMouseLeave={() => setPausa(false)} onFocus={() => setPausa(true)} onBlur={() => setPausa(false)}
      onTouchStart={(e) => { toque.current = e.touches[0].clientX }}
      onTouchEnd={(e) => { if (toque.current == null) return; const d = e.changedTouches[0].clientX - toque.current; if (Math.abs(d) > 50) ir(i + (d < 0 ? 1 : -1)); toque.current = null }}>
      <div className="t-hero-ventana">
        <div className="t-hero-pista" style={{ transform: `translateX(-${i * 100}%)` }}>
          {banners.length ? banners.map((u, k) => (
            <div className="t-slide" key={k} role="group" aria-roledescription="diapositiva" aria-label={`${k + 1} de ${n}`} aria-hidden={k !== i}>
              <img src={u} alt={`Promoción ${k + 1}`} loading={k === 0 ? 'eager' : 'lazy'} />
            </div>
          )) : (
            <div className="t-slide portada">
              <div>
                <h1>Perfumes de diseñador y árabes, <i>para tu estilo</i></h1>
                <p>{info.mensaje || 'Calidad 1.1, envíos a todo el país y pedido por WhatsApp en minutos.'}</p>
                <div className="t-hero-cta">
                  <a className="t-btn dorado" href="#catalogo">Ver el catálogo</a>
                  <button type="button" className="t-btn claro" onClick={onQuiz}>Encuentra tu perfume</button>
                </div>
              </div>
            </div>
          )}
        </div>
      </div>
      {n > 1 && (<>
        <button className="t-flecha izq" onClick={() => ir(i - 1)} aria-label="Banner anterior"><Icono d={iFlechaIzq} /></button>
        <button className="t-flecha der" onClick={() => ir(i + 1)} aria-label="Banner siguiente"><Icono d={iFlechaDer} /></button>
        <div className="t-hero-pie">
          <span>{String(i + 1).padStart(2, '0')} — {String(n).padStart(2, '0')}</span>
          <div className="t-puntos">
            {banners.map((_, k) => <button key={k} className={k === i ? 'on' : ''} onClick={() => ir(k)} aria-label={`Ir al banner ${k + 1}`} />)}
          </div>
          <span className="t-hero-etq">Promociones del mes</span>
        </div>
      </>)}
    </section>
  )
}

function Ficha({ p, tab, umbral, tasa, carro, cambiar, setAgendar, abrirFicha, fav, alternarFav, top }) {
  const sinPrecio = p.precio_detal == null
  const sinStock = p.stock < 1
  const agendable = sinStock || sinPrecio     // no se puede comprar ahora: se agenda y le avisamos
  const tono = tonoDe(p.nombre)
  const enCarro = carro[p.id] || 0
  const precio = tab === 'mayor' ? num(p.precio_mayor) : num(p.precio_detal)
  return (
    <article className="t-card">
      <div className="t-foto" style={{ background: tono.fondo }} onClick={() => abrirFicha(p)}>
        {p.foto_url ? <img className="f1" src={p.foto_url} alt={p.nombre} loading="lazy" /> : <Botella nombre={p.nombre} tono={tono} />}
        {p.foto2_url && <img className="f2" src={p.foto2_url} alt={`${p.nombre}, segunda foto`} loading="lazy" />}
        {sinStock
          ? <span className="t-sello pronto">Por llegar pronto</span>
          : !agendable && (p.stock <= 2
            ? <span className="t-sello poco">{p.stock === 1 ? 'Última unidad' : `Quedan ${p.stock}`}</span>
            : <span className="t-sello disp">Disponible</span>)}
        {p.foto2_url && <span className="t-dos" aria-hidden="true"><i /><i /></span>}
        {(p.es_nuevo || top) && !sinStock && <span className="t-etq">{p.es_nuevo ? 'Nuevo' : 'Más vendido'}</span>}
        <button type="button" className={'t-fav' + (fav ? ' on' : '')} aria-pressed={fav} aria-label={(fav ? 'Quitar de favoritos: ' : 'Guardar en favoritos: ') + p.nombre} onClick={(e) => { e.stopPropagation(); alternarFav(p.id) }}>{fav ? '♥' : '♡'}</button>
      </div>
      <div className="t-info">
        <h3><button type="button" className="t-nombre-btn" onClick={() => abrirFicha(p)}>{p.nombre}</button></h3>
        {(p.marca || p.genero) && <small className="t-meta">{[p.marca, GENERO[p.genero]].filter(Boolean).join(' · ')}</small>}
        {p.familia && <small className="t-familia">{p.familia}</small>}
        {p.descripcion && <p className="t-desc" title={p.descripcion}>{p.descripcion}</p>}
        {sinPrecio ? (
          <div className="t-precio"><b className="t-por-confirmar">Precio por confirmar</b></div>
        ) : (
          <div className="t-precio">
            <b>{$(precio)}</b>
            {tasa && <small>{Bs(precio, tasa.euro)}</small>}
          </div>
        )}
        <small className="t-nota">
          {sinPrecio ? 'Agéndalo y te escribimos con el precio' : sinStock ? 'Te avisamos por WhatsApp cuando llegue' : tab === 'mayor' ? (num(p.precio_mayor) < num(p.precio_detal) ? `Al detal ${$(p.precio_detal)} · el mayor aplica con ${umbral} perfumes` : ' ')
            : (num(p.precio_mayor) < num(p.precio_detal) ? `Al mayor ${$(p.precio_mayor)} con ${umbral} perfumes (pueden ser diferentes)` : ' ')}
        </small>
      </div>
      {agendable
        ? <button className="t-btn sec" onClick={() => setAgendar(p)}>{sinPrecio ? 'Consultar precio' : 'Agendar pedido'}</button>
        : enCarro
          ? (
            <div className="t-paso" role="group" aria-label={`Cantidad de ${p.nombre}`}>
              <button onClick={() => cambiar(p.id, -1)} aria-label="Quitar uno">−</button>
              <output>{enCarro}</output>
              <button onClick={() => cambiar(p.id, 1)} disabled={enCarro >= p.stock} aria-label="Agregar uno">+</button>
            </div>
          )
          : <button className="t-btn" onClick={() => cambiar(p.id, 1)}>Agregar al carrito</button>}
    </article>
  )
}

// Ficha completa de un perfume. Tiene link propio (/p/ID) y botón para compartirlo por WhatsApp.
function Detalle({ p, cat, tasa, umbral, carro, cambiar, setAgendar, info, setAviso, abrirFicha, favs, alternarFav, onCerrar }) {
  const [foto, setFoto] = useState(0)
  useEffect(() => { setFoto(0) }, [p.id])
  const niveles = parseNotas(p.notas)
  const similares = p.familia ? cat.filter((x) => x.id !== p.id && x.familia === p.familia && x.stock > 0 && x.precio_detal != null).slice(0, 3) : []
  const fotos = [p.foto_url, p.foto2_url].filter(Boolean)
  const sinPrecio = p.precio_detal == null
  const agendable = p.stock < 1 || sinPrecio
  const tono = tonoDe(p.nombre)
  const enCarro = carro[p.id] || 0
  useEffect(() => {
    const k = (e) => e.key === 'Escape' && onCerrar()
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k)
  }, [onCerrar])
  const texto = `${p.nombre}${p.marca ? ' · ' + p.marca : ''}${sinPrecio ? '' : '\nPrecio: ' + $(p.precio_detal) + (num(p.precio_mayor) < num(p.precio_detal) ? ` (al mayor ${$(p.precio_mayor)} desde ${umbral} perfumes)` : '')}` +
    (p.descripcion ? '\n' + p.descripcion.slice(0, 140) + (p.descripcion.length > 140 ? '…' : '') : '') + `\nMíralo aquí: ${linkDe(p.id)}`
  const copiar = async () => {
    try { await navigator.clipboard.writeText(linkDe(p.id)); setAviso('Link copiado') } catch { setAviso(linkDe(p.id)) }
  }
  return (
    <div className="t-cortina centro" onClick={onCerrar}>
      <div className="t-modal t-detalle" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={p.nombre}>
        <button className="t-cerrar" onClick={onCerrar} aria-label="Cerrar ficha">×</button>
        <div className="t-det-foto" style={{ background: tono.fondo }}>
          {fotos.length ? <img src={fotos[Math.min(foto, fotos.length - 1)]} alt={p.nombre} /> : <Botella nombre={p.nombre} tono={tono} />}
          {fotos.length > 1 && (
            <div className="t-det-puntos">{fotos.map((_, k) => <button key={k} className={k === foto ? 'on' : ''} onClick={() => setFoto(k)} aria-label={`Foto ${k + 1}`} />)}</div>
          )}
        </div>
        <div>
          {(p.marca || p.genero) && <small className="t-meta">{[p.marca, GENERO[p.genero]].filter(Boolean).join(' · ')}</small>}
          <h2>{p.nombre}</h2>
          {sinPrecio ? <p className="t-por-confirmar">Precio por confirmar</p> : (
            <div className="t-det-precios">
              <div><b>{$(p.precio_detal)}</b><small>al detal{tasa ? ` · ${Bs(p.precio_detal, tasa.euro)}` : ''}</small></div>
              {num(p.precio_mayor) < num(p.precio_detal) && <div><b>{$(p.precio_mayor)}</b><small>al mayor desde {umbral} perfumes</small></div>}
            </div>
          )}
          {p.descripcion && <p>{p.descripcion}</p>}
          {niveles
            ? <dl className="t-niveles">{niveles.map(([n, v]) => <div key={n}><dt>{n}</dt><dd>{v}</dd></div>)}</dl>
            : p.notas && <p className="t-notas"><b>Notas:</b> {p.notas}</p>}
          {(p.familia || p.duracion || p.ocasion) && (
            <div className="t-perfil">
              {p.familia && <span><small>Familia</small><b>{p.familia}</b></span>}
              {p.ocasion && <span><small>Ocasión</small><b>{p.ocasion}</b></span>}
              {p.duracion && <span><small>Duración</small><b>{p.duracion}</b></span>}
            </div>
          )}
          <p className="t-disp">{agendable ? (sinPrecio ? 'Agéndalo y te escribimos con el precio.' : 'Por llegar pronto: agéndalo y te avisamos apenas llegue.') : p.stock <= 2 ? (p.stock === 1 ? 'Última unidad' : `Quedan ${p.stock}`) : 'Disponible'}</p>
        </div>
        <div className="t-acciones col">
          {agendable
            ? <button className="t-btn" onClick={() => { onCerrar(); setAgendar(p) }}>{sinPrecio ? 'Consultar precio' : 'Agendar pedido'}</button>
            : enCarro
              ? (
                <div className="t-paso" role="group" aria-label={`Cantidad de ${p.nombre}`}>
                  <button onClick={() => cambiar(p.id, -1)} aria-label="Quitar uno">−</button><output>{enCarro}</output>
                  <button onClick={() => cambiar(p.id, 1)} disabled={enCarro >= p.stock} aria-label="Agregar uno">+</button>
                </div>
              )
              : <button className="t-btn" onClick={() => { cambiar(p.id, 1); setAviso('Agregado: ' + p.nombre) }}>Agregar al carrito</button>}
          <a className="t-btn sec" href={`https://wa.me/?text=${encodeURIComponent(texto)}`} target="_blank" rel="noopener noreferrer">Compartir por WhatsApp</a>
          <button className="t-btn sec" onClick={copiar}>Copiar link</button>
          <button className="t-btn sec" aria-pressed={favs.includes(p.id)} onClick={() => alternarFav(p.id)}>{favs.includes(p.id) ? '♥ En favoritos' : '♡ Guardar en favoritos'}</button>
        </div>
        {similares.length > 0 && (
          <div className="t-similares">
            <h3>Si te gusta este, mira también</h3>
            <div>{similares.map((x) => (
              <button type="button" key={x.id} onClick={() => abrirFicha(x)}>
                <span style={{ background: tonoDe(x.nombre).fondo }}>{x.foto_url ? <img src={x.foto_url} alt="" /> : <Botella nombre={x.nombre} tono={tonoDe(x.nombre)} />}</span>
                <small>{x.marca}</small><b>{x.nombre}</b><em>{$(x.precio_detal)}</em>
              </button>
            ))}</div>
          </div>
        )}
      </div>
    </div>
  )
}

function Cajon({ onCerrar, lineas, unidades, umbral, mayor, total, ahorro, tasa, info, precioDe, cambiar, setCarro, cargar, setListo }) {
  const [f, setF] = useState(() => ({
    nombre: '', apellido: '', telefono: '', ubicacion: '', delivery: '', entrega: '', notas: '', metodo: '',
    ...guardado('tienda-datos', {}),
  }))
  const [err, setErr] = useState('')
  const [enviando, setEnviando] = useState(false)
  const faltan = Math.max(umbral - unidades, 0)
  const metodos = info.metodos || []
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })

  useEffect(() => {
    const k = (e) => e.key === 'Escape' && onCerrar()
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k)
  }, [onCerrar])

  const enviar = async (e) => {
    e.preventDefault(); setErr('')
    if (!f.delivery) return setErr('Cuéntanos si necesitas delivery.')
    setEnviando(true)
    const delivery = f.delivery === 'si'
    const { data, error } = await rpc('tienda_crear_pedido', {
      p_nombre: f.nombre, p_apellido: f.apellido, p_telefono: f.telefono, p_ubicacion: f.ubicacion,
      p_delivery: delivery, p_entrega: delivery ? f.entrega : '', p_notas: f.notas, p_metodo: f.metodo,
      p_items: lineas.map((l) => ({ perfume_id: l.p.id, unidades: l.u })),
    })
    setEnviando(false)
    if (error) { setErr(error.message); cargar(); return }
    guardar('tienda-datos', { nombre: f.nombre, apellido: f.apellido, telefono: f.telefono, ubicacion: f.ubicacion })
    const detalle = lineas.map((l) => ({ nombre: l.p.nombre, u: l.u, precio: precioDe(l.p) }))
    setListo({ ...data, detalle, cliente: `${f.nombre.trim()} ${f.apellido.trim()}`, telefono: f.telefono, ubicacion: f.ubicacion, delivery, entrega: f.entrega, metodo: f.metodo, notas: f.notas })
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
                : <p>Agrega <b>{faltan}</b> {faltan === 1 ? 'perfume más' : 'perfumes más'} (pueden ser diferentes) y todo tu pedido pasa al precio al mayor.</p>}
              <div className="t-barra"><i style={{ width: Math.min(100, (unidades / umbral) * 100) + '%' }} /></div>
            </div>

            <div className="t-total"><span>Total</span><div><b>{$(total)}</b>{tasa && <small>{Bs(total, tasa.euro)} a tasa BCV Euro</small>}</div></div>

            <h3 className="t-subtitulo">Tus datos</h3>
            <div className="t-dos-cols">
              <label className="t-campo"><span>Nombre</span><input value={f.nombre} onChange={set('nombre')} required autoComplete="given-name" minLength={2} /></label>
              <label className="t-campo"><span>Apellido</span><input value={f.apellido} onChange={set('apellido')} required autoComplete="family-name" minLength={2} /></label>
            </div>
            <label className="t-campo"><span>Teléfono de contacto (WhatsApp)</span><input value={f.telefono} onChange={set('telefono')} required inputMode="tel" autoComplete="tel" placeholder="0414-1234567" /></label>
            <label className="t-campo"><span>¿En qué zona o ciudad te encuentras?</span><input value={f.ubicacion} onChange={set('ubicacion')} required minLength={3} autoComplete="address-level2" placeholder="Ej. Altamira, Caracas" /></label>

            <fieldset className="t-campo t-opciones">
              <legend>¿Necesitas delivery?</legend>
              <label className={f.delivery === 'si' ? 'on' : ''}><input type="radio" name="delivery" value="si" checked={f.delivery === 'si'} onChange={set('delivery')} />Sí, necesito delivery</label>
              <label className={f.delivery === 'no' ? 'on' : ''}><input type="radio" name="delivery" value="no" checked={f.delivery === 'no'} onChange={set('delivery')} />No, coordinamos la entrega</label>
            </fieldset>
            {f.delivery === 'si' && (
              <label className="t-campo"><span>¿Hasta dónde lo llevamos?</span>
                <input value={f.entrega} onChange={set('entrega')} required minLength={3} placeholder="Dirección o punto de referencia" /></label>
            )}

            {metodos.length > 0 && (
              <label className="t-campo"><span>¿Cómo vas a pagar?</span>
                <select value={f.metodo} onChange={set('metodo')} required>
                  <option value="">Elige una opción</option>
                  {metodos.map((m, i) => <option key={i}>{m.titulo}</option>)}
                </select>
              </label>
            )}
            <label className="t-campo"><span>Notas (opcional)</span><input value={f.notas} onChange={set('notas')} placeholder="Regalo, horario, etc." /></label>
            {err && <p className="t-error" role="alert">{err}</p>}
            <button className="t-btn grande" type="submit" disabled={enviando}>{enviando ? 'Enviando…' : 'Enviar pedido por WhatsApp'}</button>
            <p className="t-ayuda">Apartamos tus perfumes al enviar. Te confirmamos el pago y la entrega por WhatsApp.</p>
          </form>
        )}
      </aside>
    </div>
  )
}

// Quiz de 3 preguntas: para quién, para qué ocasión y qué aroma. Recomienda 3 perfumes con stock.
function Quiz({ cat, tasa, umbral, onCerrar, carro, cambiar, abrirFicha, setAviso }) {
  const [paso, setPaso] = useState(0)
  const [r, setR] = useState({ genero: null, ocasion: null, familia: null })
  const preguntas = [
    { k: 'genero', t: '¿Para quién es?', a: 'Elige una.', o: [['mujer', 'Para ella'], ['hombre', 'Para él'], ['unisex', 'Unisex', 'Sin distinción']] },
    { k: 'ocasion', t: '¿Para qué ocasión lo quieres?', a: 'Elige una.', o: [['Salidas', 'Una salida con amigos', 'Fiestas, cenas, noche larga'], ['Día a día', 'Trabajo y día a día', 'Oficina, clases, calle'], ['Citas', 'Una cita', 'Que se note sin exagerar'], ['', 'Para mí, sin ocasión', 'Lo uso porque me gusta']] },
    { k: 'familia', t: '¿Qué aroma te gusta?', a: 'Elige el que más te atraiga.', o: [['Dulce', 'Dulce y cremoso', 'Vainilla, frutas, caramelo'], ['Fresco', 'Fresco y limpio', 'Cítricos, notas marinas'], ['Amaderado', 'Amaderado o especiado', 'Madera, ámbar, canela'], ['Floral', 'Floral', 'Rosa, jazmín, peonía'], ['Gourmand', 'Gourmand', 'Café, cacao, praliné']] },
  ]
  const hecho = paso >= preguntas.length
  const afines = { Dulce: ['Dulce', 'Gourmand'], Gourmand: ['Gourmand', 'Dulce'], Amaderado: ['Amaderado', 'Ámbar y especiado'], Fresco: ['Fresco'], Floral: ['Floral', 'Dulce'] }
  const resultados = useMemo(() => {
    if (!hecho) return []
    return cat.filter((p) => p.stock > 0 && p.precio_detal != null).map((p) => {
      let pts = 0
      if (r.genero) pts += p.genero === r.genero ? 4 : p.genero === 'unisex' ? 2 : p.genero ? -6 : 0
      if (r.ocasion) pts += tieneOcasion(p, r.ocasion) ? 2 : 0
      if (r.familia) pts += p.familia === r.familia ? 4 : (afines[r.familia] || []).includes(p.familia) ? 2 : 0
      return { p, pts: pts + Math.min(p.vendidos, 10) / 20 }
    }).filter((x) => x.pts > 0).sort((a, b) => b.pts - a.pts).slice(0, 3)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hecho, cat, r])
  const maxPts = (r.genero ? 4 : 0) + (r.ocasion ? 2 : 0) + (r.familia ? 4 : 0) || 1
  const elegir = (k, v) => { setR({ ...r, [k]: v }); setPaso(paso + 1) }

  useEffect(() => {
    const k = (e) => e.key === 'Escape' && onCerrar()
    window.addEventListener('keydown', k); return () => window.removeEventListener('keydown', k)
  }, [onCerrar])

  const q = preguntas[paso]
  return (
    <div className="t-cortina centro" onClick={onCerrar}>
      <div className="t-modal t-quiz" onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label="Encuentra tu perfume">
        <button className="t-cerrar" onClick={onCerrar} aria-label="Cerrar quiz">×</button>
        {!hecho ? (
          <>
            <div className="t-quiz-prog" aria-hidden="true">{preguntas.map((_, i) => <i key={i} className={i <= paso ? 'on' : ''} />)}</div>
            <small className="t-quiz-paso">Pregunta {paso + 1} de {preguntas.length}</small>
            <h2>{q.t}</h2>
            <p className="t-quiz-ayuda">{q.a}</p>
            <div className="t-quiz-ops">
              {q.o.map(([v, n, d]) => (
                <button type="button" key={v || 'ninguna'} className={r[q.k] === v ? 'on' : ''} onClick={() => elegir(q.k, v)}><b>{n}</b>{d && <small>{d}</small>}</button>
              ))}
            </div>
            {paso > 0 && <button type="button" className="t-quiz-atras" onClick={() => setPaso(paso - 1)}>Atrás</button>}
          </>
        ) : (
          <>
            <h2>{resultados.length ? 'Tus perfumes ideales' : 'Por ahora no tenemos uno exacto'}</h2>
            <p className="t-quiz-ayuda">{resultados.length ? 'Los que mejor encajan con tus respuestas y están disponibles.' : 'Mira todo el catálogo o escríbenos y te ayudamos.'}</p>
            <div className="t-quiz-res">
              {resultados.map(({ p, pts }, i) => (
                <article key={p.id} className={i === 0 ? 'mejor' : ''}>
                  {i === 0 && <span className="t-quiz-mejor">Tu mejor opción · {Math.min(99, Math.round(60 + (pts / maxPts) * 39))}% de afinidad</span>}
                  <div className="t-quiz-fila">
                    <span className="t-quiz-foto" style={{ background: tonoDe(p.nombre).fondo }}>{p.foto_url ? <img src={p.foto_url} alt="" /> : <Botella nombre={p.nombre} tono={tonoDe(p.nombre)} />}</span>
                    <div><small>{[p.marca, p.familia].filter(Boolean).join(' · ')}</small><h3>{p.nombre}</h3><b>{$(p.precio_detal)}</b>{tasa && <small> · {Bs(p.precio_detal, tasa.euro)}</small>}</div>
                  </div>
                  <div className="t-acciones">
                    <button className="t-btn sec" onClick={() => { onCerrar(); abrirFicha(p) }}>Ver detalle</button>
                    <button className="t-btn" onClick={() => { cambiar(p.id, 1); setAviso('Agregado: ' + p.nombre) }} disabled={(carro[p.id] || 0) >= p.stock}>Agregar</button>
                  </div>
                </article>
              ))}
            </div>
            <div className="t-acciones">
              <button className="t-btn sec" onClick={() => { setPaso(0); setR({ genero: null, ocasion: null, familia: null }) }}>Repetir quiz</button>
              <a className="t-btn" href="#catalogo" onClick={onCerrar}>Ver catálogo</a>
            </div>
          </>
        )}
      </div>
    </div>
  )
}

function Agendar({ p, onCerrar, onListo }) {
  const [f, setF] = useState(() => ({ nombre: '', apellido: '', telefono: '', unidades: 1, ...guardado('tienda-datos', {}) }))
  const [err, setErr] = useState('')
  const enviar = async (e) => {
    e.preventDefault(); setErr('')
    const { error } = await rpc('tienda_agendar', { p_perfume_id: p.id, p_cliente: `${f.nombre.trim()} ${f.apellido.trim()}`, p_telefono: f.telefono, p_unidades: Number(f.unidades) })
    if (error) return setErr(error.message)
    guardar('tienda-datos', { ...guardado('tienda-datos', {}), nombre: f.nombre, apellido: f.apellido, telefono: f.telefono })
    onListo(`Listo. Te escribimos cuando llegue ${p.nombre}.`)
  }
  return (
    <div className="t-cortina centro" onClick={onCerrar}>
      <form className="t-modal" onSubmit={enviar} onClick={(e) => e.stopPropagation()} role="dialog" aria-modal="true" aria-label={`Agendar ${p.nombre}`}>
        <h2>Agendar {p.nombre}</h2>
        <p className="t-ayuda">Ahora no lo tenemos disponible para compra directa. Déjanos tus datos y te escribimos por WhatsApp con el precio o apenas llegue. No tiene costo ni te compromete a comprar.</p>
        <div className="t-dos-cols">
          <label className="t-campo"><span>Nombre</span><input value={f.nombre} onChange={(e) => setF({ ...f, nombre: e.target.value })} required minLength={2} autoComplete="given-name" /></label>
          <label className="t-campo"><span>Apellido</span><input value={f.apellido} onChange={(e) => setF({ ...f, apellido: e.target.value })} required minLength={2} autoComplete="family-name" /></label>
        </div>
        <label className="t-campo"><span>Teléfono de contacto (WhatsApp)</span><input value={f.telefono} onChange={(e) => setF({ ...f, telefono: e.target.value })} required inputMode="tel" autoComplete="tel" placeholder="0414-1234567" /></label>
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
    (info.tasa?.euro ? `\nEn bolívares: ${Bs(r.total, info.tasa.euro)} (tasa BCV Euro ${num(info.tasa.euro).toLocaleString('es-VE')})` : '') +
    (r.metodo ? `\nPago: ${r.metodo}` : '') +
    `\n\nNombre: ${r.cliente}\nTeléfono: ${r.telefono}\nZona: ${r.ubicacion}` +
    `\nDelivery: ${r.delivery ? 'Sí, hasta ' + r.entrega : 'No, coordinamos la entrega'}` + (r.notas ? `\nNotas: ${r.notas}` : '')
  const numero = digitos(info.whatsapp) || WHATSAPP_POR_DEFECTO
  const enlace = `https://wa.me/${numero}?text=${encodeURIComponent(texto)}`
  return (
    <div className="t-cortina centro">
      <div className="t-modal" role="dialog" aria-modal="true" aria-label="Pedido recibido">
        <h2>Pedido {r.codigo} recibido</h2>
        <p>Apartamos tus perfumes por <b>{$(r.total)}</b>. Falta un paso: <b>envíanos el pedido por WhatsApp</b> para que lo confirmemos y coordinemos el pago.</p>
        <a className="t-btn grande" href={enlace} target="_blank" rel="noreferrer">Enviar pedido por WhatsApp</a>
        <button className="t-btn sec" onClick={onCerrar}>Seguir viendo perfumes</button>
      </div>
    </div>
  )
}
