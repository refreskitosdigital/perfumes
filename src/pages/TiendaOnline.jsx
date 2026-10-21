import React, { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Aviso, Guia, Insignia, Tarjeta } from '../ui.jsx'
import { usd, num, waLink } from '../lib.js'
import { reducirImagen } from '../imagen.js'

const fechaHora = (t) => new Date(t).toLocaleString('es-VE', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: 'America/Caracas' })

export default function TiendaOnline() {
  const [vista, setVista] = useState('pedidos')
  const ped = useQuery(() => supabase.from('pedidos_web').select('*').order('creado', { ascending: false }).limit(300), [])
  const dem = useQuery(() => supabase.from('demanda_web').select('*').order('creado', { ascending: false }), [])
  const nuevos = ped.data.filter((p) => p.estado === 'nuevo').length
  const porAtender = new Set(dem.data.filter((d) => !d.atendido).map((d) => d.perfume_id)).size
  const enlace = (import.meta.env.VITE_URL_TIENDA || '').replace(/\/+$/, '') || `${window.location.origin}/tienda`
  const [copiado, setCopiado] = useState(false)
  const copiar = async () => { try { await navigator.clipboard.writeText(enlace); setCopiado(true); setTimeout(() => setCopiado(false), 2000) } catch { window.prompt('Copia el enlace:', enlace) } }

  return (
    <>
      <Guia>Esta es la <b>tienda online</b>. Los pedidos que hace la gente llegan aquí con el stock ya apartado: tú los <b>confirmas</b> (se convierten en ventas y los datos del cliente se guardan solos) o los <b>cancelas</b> (el stock vuelve a estar disponible). Enlace de la tienda: <a href={enlace} target="_blank" rel="noreferrer"><b>{enlace}</b></a> <button onClick={copiar}>{copiado ? '¡Copiado!' : 'Copiar enlace'}</button></Guia>
      <div className="subtabs">
        <button className={vista === 'pedidos' ? 'on' : ''} onClick={() => setVista('pedidos')}>Pedidos {nuevos > 0 && <Insignia tono="warn">{nuevos} nuevos</Insignia>}</button>
        <button className={vista === 'demanda' ? 'on' : ''} onClick={() => setVista('demanda')}>Agendados (agotados) {porAtender > 0 && <Insignia>{porAtender}</Insignia>}</button>
        <button className={vista === 'banners' ? 'on' : ''} onClick={() => setVista('banners')}>Banners</button>
        <button className={vista === 'ajustes' ? 'on' : ''} onClick={() => setVista('ajustes')}>Ajustes de la tienda</button>
      </div>
      <Aviso error={ped.error || dem.error} />
      {vista === 'pedidos' && <Pedidos ped={ped} />}
      {vista === 'demanda' && <Demanda dem={dem} />}
      {vista === 'banners' && <Banners />}
      {vista === 'ajustes' && <Ajustes />}
    </>
  )
}

function Pedidos({ ped }) {
  const { perfumes, socios, miSocio } = useApp()
  const items = useQuery(() => supabase.from('pedidos_web_items').select('*').order('id'), [])
  const [solo, setSolo] = useState('nuevo')
  const [vend, setVend] = useState(miSocio?.nombre || '')
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const nombre = useMemo(() => Object.fromEntries(perfumes.data.map((p) => [p.id, p.nombre])), [perfumes.data])
  const lista = ped.data.filter((p) => solo === 'todos' || p.estado === solo)

  const confirmar = async (p) => {
    if (!vend) return setMsg({ error: 'Elige quién atiende el pedido.', ok: '' })
    if (!window.confirm(`Confirmar ${p.codigo} de ${p.cliente} por ${usd(p.total_usd)}?\nSe crean las ventas y quedan por cobrar hasta que registres el pago en la pestaña Por cobrar.`)) return
    const { error } = await supabase.rpc('confirmar_pedido_web', { p_id: p.id, p_vendedor: vend })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${p.codigo} confirmado. Ya aparece en Ventas y Por cobrar.` }); ped.recargar()
  }
  const cancelar = async (p) => {
    if (!window.confirm(`¿Cancelar el pedido ${p.codigo}? Los perfumes vuelven a estar disponibles en la tienda.`)) return
    const { error } = await supabase.rpc('cancelar_pedido_web', { p_id: p.id })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${p.codigo} cancelado.` }); ped.recargar()
  }

  return (
    <Seccion titulo="Pedidos de la tienda"
      ayuda="Los nuevos tienen el stock apartado. Confírmalos cuando hables con el cliente."
      acciones={
        <div className="filtros">
          <Campo label="Atiende"><select value={vend} onChange={(e) => setVend(e.target.value)}><option value="">Elegir…</option>{socios.map((s) => <option key={s}>{s}</option>)}</select></Campo>
          <Campo label="Ver"><select value={solo} onChange={(e) => setSolo(e.target.value)}><option value="nuevo">Nuevos</option><option value="confirmado">Confirmados</option><option value="cancelado">Cancelados</option><option value="todos">Todos</option></select></Campo>
        </div>
      }>
      <Aviso {...msg} />
      {!lista.length && <p className="vacio">{solo === 'nuevo' ? 'No hay pedidos nuevos. Cuando alguien compre en la tienda aparecerá aquí.' : 'No hay pedidos para mostrar.'}</p>}
      {lista.map((p) => {
        const its = items.data.filter((i) => i.pedido_id === p.id)
        const wa = waLink(p.telefono, `Hola ${p.cliente.split(' ')[0]}, te escribo por tu pedido ${p.codigo}.`)
        return (
          <article key={p.id} className={'pedido ' + (p.estado !== 'nuevo' ? 'hecho' : '')}>
            <header>
              <div><b>{p.codigo}</b> · {p.cliente} · {p.telefono}<br /><small className="ayuda">{fechaHora(p.creado)} · {p.metodo_pago || 'sin método'}{p.mayor ? ' · precio al mayor' : ''}</small></div>
              <div className="debe-grande"><b style={{ color: 'inherit' }}>{usd(p.total_usd)}</b></div>
              <span>
                <Insignia tono={p.estado === 'nuevo' ? 'warn' : p.estado === 'confirmado' ? 'ok' : ''}>{p.estado === 'nuevo' ? 'Nuevo' : p.estado === 'confirmado' ? 'Confirmado' : 'Cancelado'}</Insignia>
              </span>
            </header>
            <ul>{its.map((i) => <li key={i.id}>{i.unidades} × {nombre[i.perfume_id] || 'Perfume'} · {usd(i.precio_unit)} c/u</li>)}</ul>
            {(p.ubicacion || p.delivery) && (
              <p className="ayuda"><b>📍 {p.ubicacion || 'Sin zona'}</b> · {p.delivery ? <b>Delivery hasta: {p.entrega_en}</b> : 'Sin delivery (coordinar entrega)'}</p>
            )}
            {p.notas && <p className="ayuda">Notas del cliente: {p.notas}</p>}
            <div className="atajos" style={{ marginTop: 10 }}>
              {wa && <a className="boton-link" href={wa} target="_blank" rel="noreferrer">💬 Escribir por WhatsApp</a>}
              {p.estado === 'nuevo' && <><button className="primario" onClick={() => confirmar(p)}>✅ Confirmar venta</button><button onClick={() => cancelar(p)}>Cancelar pedido</button></>}
              {p.estado !== 'nuevo' && p.atendido_por && <small className="ayuda">Atendido por {p.atendido_por}</small>}
            </div>
          </article>
        )
      })}
    </Seccion>
  )
}

function Demanda({ dem }) {
  const { perfumes } = useApp()
  const [abierto, setAbierto] = useState(null)
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const nombre = useMemo(() => Object.fromEntries(perfumes.data.map((p) => [p.id, p.nombre])), [perfumes.data])
  const grupos = useMemo(() => {
    const m = new Map()
    dem.data.filter((d) => !d.atendido).forEach((d) => {
      const g = m.get(d.perfume_id) || { id: d.perfume_id, personas: [], unidades: 0 }
      g.personas.push(d); g.unidades += d.unidades; m.set(d.perfume_id, g)
    })
    return [...m.values()].sort((a, b) => b.personas.length - a.personas.length || b.unidades - a.unidades)
  }, [dem.data])
  const total = grupos.reduce((a, g) => a + g.unidades, 0)

  const atender = async (g) => {
    if (!window.confirm(`¿Marcar como atendidos a los ${g.personas.length} que pidieron ${nombre[g.id]}? Úsalo cuando ya llegó y les avisaste.`)) return
    const { error } = await supabase.from('demanda_web').update({ atendido: true }).eq('perfume_id', g.id).eq('atendido', false)
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: 'Listo, quedaron como atendidos.' }); dem.recargar()
  }

  return (
    <Seccion titulo="Perfumes agotados que la gente quiere" ayuda="Cada vez que alguien pulsa Agendar pedido en un perfume agotado queda aquí. Sirve para decidir qué traer en la próxima compra.">
      <div className="tarjetas" style={{ marginBottom: 14 }}>
        <Tarjeta titulo="Perfumes pedidos" valor={grupos.length} nota="agotados con personas esperando" />
        <Tarjeta titulo="Unidades pedidas" valor={total} nota="en total" />
      </div>
      <Aviso {...msg} />
      {!grupos.length && <p className="vacio">Todavía nadie ha agendado un perfume agotado.</p>}
      {grupos.length > 0 && (
        <div className="tabla-wrap"><table>
          <thead><tr><th>Perfume</th><th className="num">Personas</th><th className="num">Unidades</th><th /></tr></thead>
          <tbody>
            {grupos.map((g) => (
              <React.Fragment key={g.id}>
                <tr>
                  <td><b>{nombre[g.id] || 'Perfume'}</b></td>
                  <td className="num">{g.personas.length}</td><td className="num">{g.unidades}</td>
                  <td className="num"><button onClick={() => setAbierto(abierto === g.id ? null : g.id)}>Ver quiénes</button>{' '}<button onClick={() => atender(g)}>Ya llegó</button></td>
                </tr>
                {abierto === g.id && (
                  <tr><td colSpan={4} className="detalle-costos">
                    {g.personas.map((d) => (
                      <div key={d.id} className="atajos">
                        <span><b>{d.cliente}</b> · {d.telefono} · {d.unidades} u · {fechaHora(d.creado)}</span>
                        {waLink(d.telefono, `Hola ${d.cliente.split(' ')[0]}, ya llegó ${nombre[g.id]} que nos pediste.`) &&
                          <a className="boton-link" href={waLink(d.telefono, `Hola ${d.cliente.split(' ')[0]}, ya llegó ${nombre[g.id]} que nos pediste.`)} target="_blank" rel="noreferrer">💬 Avisar por WhatsApp</a>}
                      </div>
                    ))}
                  </td></tr>
                )}
              </React.Fragment>
            ))}
          </tbody>
        </table></div>
      )}
    </Seccion>
  )
}

function Ajustes() {
  const cfg = useQuery(() => supabase.from('tienda_config').select('*').eq('id', 1), [])
  const [f, setF] = useState(null)
  const [msg, setMsg] = useState({ error: '', ok: '' })
  useEffect(() => { if (cfg.data[0] && !f) setF({ ...cfg.data[0], metodos: cfg.data[0].metodos || [] }) }, [cfg.data]) // eslint-disable-line
  if (!f) return <Seccion titulo="Ajustes de la tienda"><Aviso error={cfg.error} /><p className="vacio">Cargando… Si no carga, falta correr migracion_v4.sql en Supabase.</p></Seccion>

  const metodo = (i, k, v) => setF({ ...f, metodos: f.metodos.map((m, j) => (j === i ? { ...m, [k]: v } : m)) })
  const guardar = async (e) => {
    e.preventDefault()
    const tel = String(f.whatsapp || '').replace(/\D/g, '')
    const { error } = await supabase.from('tienda_config').update({
      nombre: f.nombre.trim() || 'Perfumes', whatsapp: tel || null, umbral_mayor: Math.max(1, Math.round(num(f.umbral_mayor))),
      mensaje: f.mensaje, metodos: f.metodos.filter((m) => m.titulo.trim()),
    }).eq('id', 1)
    setMsg(error ? { error: error.message, ok: '' } : { error: '', ok: 'Ajustes guardados. La tienda ya los muestra.' })
  }

  return (
    <Seccion titulo="Ajustes de la tienda" ayuda="Lo que escribas aquí se ve en la tienda pública.">
      <form onSubmit={guardar}>
        <div className="form">
          <Campo label="Nombre de la tienda"><input value={f.nombre} onChange={(e) => setF({ ...f, nombre: e.target.value })} required /></Campo>
          <Campo label="WhatsApp que recibe los pedidos" ayuda="Con código de país, sin signos. Ej. 584141234567"><input value={f.whatsapp || ''} onChange={(e) => setF({ ...f, whatsapp: e.target.value })} inputMode="tel" placeholder="584141234567" /></Campo>
          <Campo label="Precio al mayor desde (perfumes)" ayuda="Se cuentan todos los del carrito, de cualquier tipo"><input type="number" min="1" value={f.umbral_mayor} onChange={(e) => setF({ ...f, umbral_mayor: e.target.value })} required /></Campo>
        </div>
        <div className="form"><Campo label="Frase bajo el título"><input value={f.mensaje || ''} onChange={(e) => setF({ ...f, mensaje: e.target.value })} /></Campo></div>
        <h3>Métodos de pago</h3>
        <p className="ayuda">Los que escribas aquí se muestran en la tienda y el cliente elige uno al pedir. Puedes poner los datos del pago móvil, del Binance, etc.</p>
        {f.metodos.map((m, i) => (
          <div className="form" key={i}>
            <Campo label="Nombre"><input value={m.titulo} onChange={(e) => metodo(i, 'titulo', e.target.value)} placeholder="Pago móvil" /></Campo>
            <Campo label="Datos o instrucciones"><input value={m.detalle} onChange={(e) => metodo(i, 'detalle', e.target.value)} placeholder="Banco, cédula y teléfono" /></Campo>
            <button type="button" onClick={() => setF({ ...f, metodos: f.metodos.filter((_, j) => j !== i) })}>Quitar</button>
          </div>
        ))}
        <div className="atajos">
          <button type="button" onClick={() => setF({ ...f, metodos: [...f.metodos, { titulo: '', detalle: '' }] })}>+ Agregar método de pago</button>
          <button className="primario" type="submit">Guardar ajustes</button>
        </div>
        <Aviso {...msg} />
      </form>
    </Seccion>
  )
}

function Banners() {
  const ban = useQuery(() => supabase.from('tienda_banners').select('*').order('orden'), [])
  const [subiendo, setSubiendo] = useState(0)
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const porOrden = Object.fromEntries(ban.data.map((b) => [b.orden, b]))

  const subir = async (orden, archivo) => {
    if (!archivo) return
    setSubiendo(orden); setMsg({ error: '', ok: '' })
    try {
      const blob = await reducirImagen(archivo, 1920, 0.88)
      const ruta = `banners/banner-${orden}-${Date.now()}.jpg`
      const up = await supabase.storage.from('perfumes').upload(ruta, blob, { contentType: 'image/jpeg', upsert: true })
      if (up.error) throw up.error
      const { data } = supabase.storage.from('perfumes').getPublicUrl(ruta)
      const { error } = await supabase.from('tienda_banners').upsert({ orden, url: data.publicUrl, activo: true }, { onConflict: 'orden' })
      if (error) throw (/tienda_banners/.test(error.message) ? new Error('Falta ejecutar migracion_v5.sql en Supabase.') : error)
      setMsg({ error: '', ok: `Banner ${orden} guardado. Ya se ve en la tienda.` }); ban.recargar()
    } catch (e) { setMsg({ error: e.message || String(e), ok: '' }) } finally { setSubiendo(0) }
  }
  const quitar = async (orden) => {
    if (!window.confirm(`¿Quitar el banner ${orden} de la tienda?`)) return
    const { error } = await supabase.from('tienda_banners').delete().eq('orden', orden)
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Banner ${orden} quitado.` }); ban.recargar()
  }

  return (
    <Seccion titulo="Banners del inicio de la tienda"
      ayuda="Sube hasta 4 banners para las promociones del mes. Se deslizan solos en la parte superior de la tienda, en el orden 1 a 4.">
      <Guia>Medida recomendada: <b>1920 × 640 px</b> (formato largo, 3 de ancho por 1 de alto). Deja el texto importante en el centro para que se vea bien en el celular. Si no subes ninguno, la tienda muestra una portada con el nombre.</Guia>
      <Aviso error={ban.error} />
      <Aviso {...msg} />
      {[1, 2, 3, 4].map((n) => {
        const b = porOrden[n]
        return (
          <div className="banner-fila" key={n}>
            <b style={{ fontSize: 22, width: 28 }}>{n}</b>
            {b ? <img src={b.url} alt={`Banner ${n}`} /> : <div className="sin-foto">Espacio libre</div>}
            <div className="atajos">
              <label className="boton-link" style={{ cursor: 'pointer' }}>
                {subiendo === n ? 'Subiendo…' : b ? '📷 Cambiar imagen' : '📷 Subir banner'}
                <input type="file" accept="image/*" hidden disabled={subiendo === n} onChange={(e) => { subir(n, e.target.files?.[0]); e.target.value = '' }} />
              </label>
              {b && <button onClick={() => quitar(n)}>Quitar</button>}
            </div>
          </div>
        )
      })}
    </Seccion>
  )
}
