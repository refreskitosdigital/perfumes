import React, { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Tarjeta, Aviso, Guia, Insignia } from '../ui.jsx'
import { usd, num, normNombre, waLink } from '../lib.js'
import { descargarExcel } from '../excel.js'

const MEDALLA = ['🥇', '🥈', '🥉']

export default function Clientes() {
  const cli = useQuery(() => supabase.from('clientes').select('*').order('nombre'), [])
  const ven = useQuery(() => supabase.from('ventas_v')
    .select('id,fecha,cliente,nombre,unidades,precio_unit,base,valor_usd,cobrado_usd,pendiente_usd,vence,vendedor,tasa_bcv,tasa_binance').order('fecha', { ascending: false }).limit(5000), [])
  const cob = useQuery(() => supabase.from('cobros').select('id,venta_id,fecha,cuenta,monto,tasa_bcv,tasa_binance').order('fecha').order('id').limit(10000), [])
  const [anio, setAnio] = useState('todos')
  const [buscar, setBuscar] = useState('')
  const [sel, setSel] = useState(null)
  const [nuevo, setNuevo] = useState({ nombre: '', telefono: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const anios = useMemo(() => [...new Set(ven.data.map((v) => String(v.fecha).slice(0, 4)))].sort().reverse(), [ven.data])

  // Cada cobro con su equivalente en dólares (misma cuenta que usa la base de datos)
  const cobrosPorVenta = useMemo(() => {
    const m = new Map(); const ventas = new Map(ven.data.map((v) => [v.id, v]))
    cob.data.forEach((c) => {
      const v = ventas.get(c.venta_id); if (!v) return
      const tasa = num(c.tasa_bcv) || num(c.tasa_binance) || num(v.tasa_bcv)
      const eq = c.cuenta === 'bs' ? (tasa > 0 ? num(c.monto) / tasa : 0) : num(c.monto)
      if (!m.has(c.venta_id)) m.set(c.venta_id, [])
      m.get(c.venta_id).push({ ...c, tasa_usada: tasa, propia: !!(num(c.tasa_bcv) || num(c.tasa_binance)), eq })
    })
    return m
  }, [cob.data, ven.data])

  // Agrupa todas las ventas de un mismo cliente (sin importar mayúsculas, tildes ni si el teléfono es el mismo)
  const filas = useMemo(() => {
    const mapa = new Map(); const alias = new Map(); const porTel = new Map()
    const dig = (t) => String(t || '').replace(/\D/g, '').replace(/^(00)?58/, '').replace(/^0/, '')
    cli.data.forEach((c) => {
      const k = normNombre(c.nombre); const d = dig(c.telefono)
      if (d.length >= 7) { if (!porTel.has(d)) porTel.set(d, k); alias.set(k, porTel.get(d)) }
    })
    const get = (nombre, base) => {
      const k0 = normNombre(nombre); const k = alias.get(k0) || k0
      if (!mapa.has(k)) mapa.set(k, { key: k, id: null, nombre, telefono: '', notas: '', dias: new Set(), unidades: 0, total: 0, cobrado: 0, debe: 0, ultima: '', lineas: [], ...base })
      else if (base.id && !mapa.get(k).id) Object.assign(mapa.get(k), base)
      return mapa.get(k)
    }
    cli.data.forEach((c) => get(c.nombre, { id: c.id, nombre: c.nombre, telefono: c.telefono || '', notas: c.notas || '' }))
    ven.data.forEach((v) => {
      const c = get(v.cliente, {})
      c.lineas.push({ ...v, abonos: cobrosPorVenta.get(v.id) || [] })
      c.totalGeneral = (c.totalGeneral || 0) + num(v.valor_usd)
      c.cobradoGeneral = (c.cobradoGeneral || 0) + num(v.cobrado_usd)
      if (anio !== 'todos' && String(v.fecha).slice(0, 4) !== anio) return
      c.dias.add(v.fecha); c.unidades += num(v.unidades); c.total += num(v.valor_usd); c.cobrado += num(v.cobrado_usd)
      if (String(v.fecha).slice(0, 10) > c.ultima) c.ultima = String(v.fecha).slice(0, 10)
    })
    // Deuda real = todo lo comprado − todo lo abonado (un abono de más en una compra cubre otra compra)
    mapa.forEach((c) => { c.debe = Math.max((c.totalGeneral || 0) - (c.cobradoGeneral || 0), 0) })
    const arr = [...mapa.values()].sort((a, b) => b.total - a.total || a.nombre.localeCompare(b.nombre))
    arr.forEach((c, i) => { c.puesto = c.total > 0 ? i + 1 : null; c.compras = c.dias.size })
    return arr
  }, [cli.data, ven.data, anio, cobrosPorVenta])

  const revision = useMemo(() => revisar(filas), [filas])
  const recargarTodo = () => { cli.recargar(); ven.recargar(); cob.recargar() }

  const exportar = () => descargarExcel('clientes', {
    Clientes: filas.map((c) => ({ Cliente: c.nombre, Telefono: c.telefono, Compras: new Set(c.lineas.map((l) => l.fecha)).size, 'Comprado $': +(c.totalGeneral || 0).toFixed(2), 'Abonado $': +(c.cobradoGeneral || 0).toFixed(2), 'Debe $': +c.debe.toFixed(2) })),
    Ventas: filas.flatMap((c) => c.lineas.map((l) => ({ Fecha: String(l.fecha).slice(0, 10), Cliente: c.nombre, Perfume: l.nombre, Unidades: l.unidades, 'Precio unit $': num(l.precio_unit), 'Valor $': num(l.valor_usd), 'Abonado $': +num(l.cobrado_usd).toFixed(2), 'Debe $': +Math.max(num(l.pendiente_usd), 0).toFixed(2), Vendio: l.vendedor }))),
    Abonos: filas.flatMap((c) => c.lineas.flatMap((l) => l.abonos.map((a) => ({ Fecha: String(a.fecha).slice(0, 10), Cliente: c.nombre, Perfume: l.nombre, Cuenta: a.cuenta === 'bs' ? 'Bs' : a.cuenta === 'efectivo' ? '$ efectivo' : '$ Binance', Monto: num(a.monto), 'Tasa BCV': a.cuenta === 'bs' ? a.tasa_usada : '', 'Equivale $': +a.eq.toFixed(2) })))),
  })

  const visibles = filas.filter((c) => !buscar || normNombre(c.nombre).includes(normNombre(buscar)) || (c.telefono || '').includes(buscar))
  const podio = filas.filter((c) => c.total > 0).slice(0, 3)
  const actual = sel ? filas.find((c) => c.key === sel) : null
  const totalDeben = filas.reduce((a, c) => a + c.debe, 0)

  const crear = async (e) => {
    e.preventDefault()
    const { error } = await supabase.from('clientes').insert({ nombre: nuevo.nombre.trim(), telefono: nuevo.telefono.trim() || null })
    if (error) return setMsg({ error: error.code === '23505' ? 'Ese cliente ya existe.' : error.message, ok: '' })
    setMsg({ error: '', ok: `Cliente ${nuevo.nombre} agregado.` })
    setNuevo({ nombre: '', telefono: '' }); cli.recargar()
  }

  return (
    <>
      <Guia>Aquí se juntan <b>todas las compras de cada cliente</b>: cuánto ha comprado, cuánto debe y su historial. El ranking sirve para saber a quiénes darles un detalle a fin de año.</Guia>
      <Aviso error={cli.error || ven.error || cob.error} {...msg} />
      <Revision items={revision} abrir={(k) => { setSel(k); setTimeout(() => document.getElementById('detalle-cliente')?.scrollIntoView({ behavior: 'smooth' }), 50) }} />

      <Seccion titulo="Mejores clientes" ayuda="Se ordenan por el valor total de lo que han comprado."
        acciones={
          <Campo label="Ver">
            <select value={anio} onChange={(e) => setAnio(e.target.value)}>
              <option value="todos">Todo el tiempo</option>
              {anios.map((a) => <option key={a} value={a}>Solo {a}</option>)}
            </select>
          </Campo>
        }>
        {!podio.length ? <p className="vacio">Todavía no hay ventas para armar el ranking.</p> : (
          <div className="podio">
            {podio.map((c, i) => (
              <button key={c.key} className="podio-item" onClick={() => setSel(c.key)}>
                <div className="medalla">{MEDALLA[i]}</div>
                <b>{c.nombre}</b>
                <div className="podio-total">{usd(c.total)}</div>
                <small>{c.unidades} perfumes · {c.compras} {c.compras === 1 ? 'compra' : 'compras'}</small>
              </button>
            ))}
          </div>
        )}
      </Seccion>

      <Seccion titulo={`Todos los clientes (${filas.length})`}
        ayuda={totalDeben > 0 ? `Entre todos nos deben ${usd(totalDeben)}.` : 'Nadie debe nada.'}
        acciones={<><input className="buscador" placeholder="🔍 Buscar por nombre o teléfono" value={buscar} onChange={(e) => setBuscar(e.target.value)} /><button onClick={exportar}>⬇️ Descargar Excel</button></>}>
        <div className="tabla-wrap">
          <table className="clickable">
            <thead><tr>
              <th>#</th><th>Cliente</th><th>Teléfono</th><th className="num">Compras</th><th className="num">Perfumes</th>
              <th className="num">Total comprado</th><th className="num">Debe</th><th>Última compra</th>
            </tr></thead>
            <tbody>
              {visibles.map((c) => (
                <tr key={c.key} className={sel === c.key ? 'fila-activa' : ''} onClick={() => setSel(sel === c.key ? null : c.key)}>
                  <td>{c.puesto ? (c.puesto <= 3 ? MEDALLA[c.puesto - 1] : c.puesto) : '—'}</td>
                  <td><b>{c.nombre}</b></td>
                  <td>{c.telefono || <span className="vacio">sin teléfono</span>}</td>
                  <td className="num">{c.compras}</td>
                  <td className="num">{c.unidades}</td>
                  <td className="num">{usd(c.total)}</td>
                  <td className="num">{c.debe > 0.01 ? <b className="alerta">{usd(c.debe)}</b> : <Insignia tono="ok">al día</Insignia>}</td>
                  <td>{c.ultima || '—'}</td>
                </tr>
              ))}
              {!visibles.length && <tr><td colSpan={8} className="vacio">No se encontró ningún cliente.</td></tr>}
            </tbody>
          </table>
        </div>
      </Seccion>

      {actual && <Detalle key={actual.key} c={actual} cerrar={() => setSel(null)} recargar={cli.recargar} recargarVentas={recargarTodo} />}

      <Seccion titulo="Agregar un cliente" ayuda="Los clientes también se crean solos cuando registras una venta. Aquí puedes agregar uno con su teléfono antes de venderle.">
        <form className="form" onSubmit={crear}>
          <Campo label="Nombre"><input value={nuevo.nombre} onChange={(e) => setNuevo({ ...nuevo, nombre: e.target.value })} required /></Campo>
          <Campo label="Teléfono (opcional)"><input value={nuevo.telefono} onChange={(e) => setNuevo({ ...nuevo, telefono: e.target.value })} placeholder="0414-1234567" /></Campo>
          <button className="primario" type="submit">Agregar cliente</button>
        </form>
      </Seccion>
    </>
  )
}

function Detalle({ c, cerrar, recargar, recargarVentas }) {
  const [editando, setEditando] = useState(null)
  const [tel, setTel] = useState(c.telefono)
  const [notas, setNotas] = useState(c.notas)
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const deudas = c.lineas.filter((l) => num(l.pendiente_usd) > 0.01)
  const texto = `Hola ${c.nombre.split(' ')[0]}, te escribo de parte de Perfumes. Te recuerdo que tienes un saldo pendiente de ${usd(c.debe)}` +
    (deudas.length ? ` (${deudas.map((d) => d.nombre).join(', ')})` : '') + '. ¡Gracias por tu compra! 💐'
  const enlace = waLink(tel, texto)
  const exportarUno = () => descargarExcel(`cliente-${c.nombre}`.replace(/\s+/g, '-'), {
    Compras: c.lineas.map((l) => ({ Fecha: String(l.fecha).slice(0, 10), Perfume: l.nombre, Unidades: l.unidades, 'Precio unit $': num(l.precio_unit), 'Valor $': num(l.valor_usd), 'Abonado $': +num(l.cobrado_usd).toFixed(2), 'Debe $': +Math.max(num(l.pendiente_usd), 0).toFixed(2) })),
    Abonos: c.lineas.flatMap((l) => l.abonos.map((a) => ({ Fecha: String(a.fecha).slice(0, 10), Perfume: l.nombre, Cuenta: a.cuenta === 'bs' ? 'Bs' : '$ ' + a.cuenta, Monto: num(a.monto), 'Tasa BCV': a.cuenta === 'bs' ? a.tasa_usada : '', 'Equivale $': +a.eq.toFixed(2) }))),
  })
  const mover = async (abono, ventaId) => {
    const r = await supabase.from('cobros').update({ venta_id: Number(ventaId) }).eq('id', abono.id)
    setMsg(r.error ? { error: r.error.message, ok: '' } : { error: '', ok: 'Abono pasado a la otra compra.' })
    if (!r.error) recargarVentas()
  }

  const guardar = async () => {
    const datos = { telefono: tel.trim() || null, notas: notas.trim() || null }
    const r = c.id
      ? await supabase.from('clientes').update(datos).eq('id', c.id)
      : await supabase.from('clientes').insert({ nombre: c.nombre, ...datos })
    setMsg(r.error ? { error: r.error.message, ok: '' } : { error: '', ok: 'Datos guardados.' })
    if (!r.error) recargar()
  }

  return (
    <div id="detalle-cliente"><Seccion titulo={`Historial de ${c.nombre}`} acciones={<><button onClick={exportarUno}>⬇️ Excel de este cliente</button><button onClick={cerrar}>Cerrar ✕</button></>}>
      <div className="tarjetas">
        <Tarjeta titulo="Ha comprado" valor={usd(c.totalGeneral || 0)} nota={`${c.lineas.reduce((a, l) => a + num(l.unidades), 0)} perfumes en ${new Set(c.lineas.map((l) => l.fecha)).size} compra(s)`} />
        <Tarjeta titulo="Ha pagado" valor={usd(c.cobradoGeneral || 0)} tono="bueno" nota="Suma de todos sus abonos" />
        <Tarjeta titulo="Debe" valor={usd(c.debe)} tono={c.debe > 0.01 ? 'malo' : ''} nota="Comprado − pagado" />
        <Tarjeta titulo="Puesto en el ranking" valor={c.puesto ? '#' + c.puesto : '—'} />
      </div>
      <div className="form" style={{ marginTop: 12 }}>
        <Campo label="Teléfono"><input value={tel} onChange={(e) => setTel(e.target.value)} placeholder="0414-1234567" /></Campo>
        <Campo label="Notas (gustos, fechas, etc.)"><input value={notas} onChange={(e) => setNotas(e.target.value)} /></Campo>
        <button className="primario" onClick={guardar}>Guardar datos</button>
        {c.debe > 0.01 && enlace && <a className="boton-link" href={enlace} target="_blank" rel="noreferrer">💬 Recordar el pago por WhatsApp</a>}
      </div>
      <Aviso {...msg} />
      <h3>Estado de cuenta: cada compra con sus abonos</h3>
      <div className="tabla-wrap">
        <table>
          <thead><tr><th>Fecha</th><th>Perfume</th><th className="num">Unid.</th><th className="num">Valor</th><th className="num">Pagado</th><th className="num">Debe</th><th>Vendió</th><th /></tr></thead>
          <tbody>
            {c.lineas.flatMap((l) => {
              const demas = num(l.cobrado_usd) - num(l.valor_usd) > 0.01
              return [
                <tr key={l.id}>
                  <td>{String(l.fecha).slice(0, 10)}</td><td>{l.nombre}</td><td className="num">{l.unidades}</td>
                  <td className="num">{usd(l.valor_usd)}</td>
                  <td className="num">{usd(l.cobrado_usd)}{demas && <> <Insignia tono="warn">de más</Insignia></>}</td>
                  <td className="num">{num(l.pendiente_usd) > 0.01 ? <b className="alerta">{usd(l.pendiente_usd)}</b> : '—'}</td>
                  <td>{l.vendedor}</td>
                  <td><button onClick={() => setEditando(editando === l.id ? null : l.id)} aria-label="Editar venta y cobros">✏️</button></td>
                </tr>,
                ...l.abonos.map((a) => (
                  <tr key={'a' + a.id} className="sub">
                    <td>↳ {String(a.fecha).slice(0, 10)}</td>
                    <td colSpan={2}>Abono {a.cuenta === 'bs' ? `${num(a.monto).toLocaleString('es-VE')} Bs a ${num(a.tasa_usada)}${a.propia ? '' : ' (tasa de la venta, sin tasa propia)'}` : `${usd(a.monto)} ${a.cuenta}`}</td>
                    <td />
                    <td className="num">{usd(a.eq)}</td>
                    <td colSpan={2}>
                      {c.lineas.length > 1 && (
                        <select value="" onChange={(e) => e.target.value && mover(a, e.target.value)} aria-label="Pasar este abono a otra compra">
                          <option value="">Pasar a otra compra…</option>
                          {c.lineas.filter((x) => x.id !== l.id).map((x) => <option key={x.id} value={x.id}>{String(x.fecha).slice(0, 10)} · {x.nombre} (debe {usd(Math.max(num(x.pendiente_usd), 0))})</option>)}
                        </select>
                      )}
                    </td>
                    <td />
                  </tr>
                )),
                editando === l.id && <tr key={'e' + l.id}><td colSpan={8}><EditarVenta l={l} listo={() => { recargarVentas() }} cerrar={() => setEditando(null)} /></td></tr>,
              ]
            })}
            {!c.lineas.length && <tr><td colSpan={8} className="vacio">Este cliente todavía no tiene compras.</td></tr>}
          </tbody>
        </table>
      </div>
    </Seccion></div>
  )
}

// Corrige una venta (fecha, unidades, precio) y los cobros que ya se registraron (monto, fecha, cuenta, tasa)
function EditarVenta({ l, listo, cerrar }) {
  const cobros = useQuery(() => supabase.from('cobros').select('*').eq('venta_id', l.id).order('fecha').order('id'), [l.id])
  const [v, setV] = useState({ fecha: String(l.fecha).slice(0, 10), unidades: l.unidades, precio_unit: l.precio_unit })
  const [nuevo, setNuevo] = useState({ fecha: String(l.fecha).slice(0, 10), cuenta: 'efectivo', monto: '', tasa_bcv: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [filas, setFilas] = useState([])
  useEffect(() => { setFilas(cobros.data.map((c) => ({ ...c, fecha: String(c.fecha).slice(0, 10), tasa_bcv: c.tasa_bcv ?? '' }))) }, [cobros.data])
  const moneda = (c) => (c === 'bs' ? 'Bs' : '$')
  const fin = (r) => { if (r.error) setMsg({ error: r.error.message, ok: '' }); else { setMsg({ error: '', ok: 'Guardado.' }); cobros.recargar(); listo() } }

  const guardarVenta = async () => {
    if (!(num(v.unidades) >= 1) || num(v.precio_unit) < 0) return setMsg({ error: 'Revisa las unidades y el precio.', ok: '' })
    fin(await supabase.from('ventas').update({ fecha: v.fecha, unidades: Math.round(num(v.unidades)), precio_unit: num(v.precio_unit) }).eq('id', l.id))
  }
  const cambiar = (id, k, val) => setFilas((fs) => fs.map((f) => (f.id === id ? { ...f, [k]: val } : f)))
  const guardarCobro = async (f) => {
    if (!(num(f.monto) > 0)) return setMsg({ error: 'El monto del cobro debe ser mayor a 0.', ok: '' })
    fin(await supabase.from('cobros').update({ fecha: f.fecha, cuenta: f.cuenta, monto: num(f.monto), tasa_bcv: f.cuenta === 'bs' && num(f.tasa_bcv) > 0 ? num(f.tasa_bcv) : null }).eq('id', f.id))
  }
  const borrarCobro = async (f) => {
    if (!window.confirm(`¿Eliminar el cobro de ${moneda(f.cuenta)} ${num(f.monto).toLocaleString('es-VE')} del ${f.fecha}?`)) return
    fin(await supabase.from('cobros').delete().eq('id', f.id))
  }
  const agregarCobro = async () => {
    if (!(num(nuevo.monto) > 0)) return setMsg({ error: 'Escribe el monto del cobro.', ok: '' })
    if (nuevo.cuenta === 'bs' && !(num(nuevo.tasa_bcv) > 0)) return setMsg({ error: 'Escribe la tasa BCV a la que pagó en bolívares.', ok: '' })
    const r = await supabase.from('cobros').insert({ venta_id: l.id, fecha: nuevo.fecha, cuenta: nuevo.cuenta, monto: num(nuevo.monto), tasa_bcv: nuevo.cuenta === 'bs' && num(nuevo.tasa_bcv) > 0 ? num(nuevo.tasa_bcv) : null })
    fin(r); if (!r.error) setNuevo({ ...nuevo, monto: '', tasa_bcv: '' })
  }

  return (
    <div className="editar-venta">
      <h4>Corregir venta: {l.nombre}</h4>
      <div className="form">
        <Campo label="Fecha"><input type="date" value={v.fecha} onChange={(e) => setV({ ...v, fecha: e.target.value })} /></Campo>
        <Campo label="Unidades"><input type="number" min="1" step="1" value={v.unidades} onChange={(e) => setV({ ...v, unidades: e.target.value })} /></Campo>
        <Campo label={`Precio por unidad ($)`}><input type="number" min="0" step="0.01" value={v.precio_unit} onChange={(e) => setV({ ...v, precio_unit: e.target.value })} /></Campo>
        <button className="primario" onClick={guardarVenta}>Guardar venta</button>
      </div>
      <p className="ayuda">Total de la venta: <b>{usd(num(v.unidades) * num(v.precio_unit))}</b>. Si cambias las unidades, el inventario se ajusta solo.</p>
      <h4>Cobros de esta venta</h4>
      {!filas.length && <p className="vacio">Esta venta no tiene cobros registrados.</p>}
      {filas.map((f) => (
        <div className="form" key={f.id}>
          <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => cambiar(f.id, 'fecha', e.target.value)} /></Campo>
          <Campo label="Cuenta">
            <select value={f.cuenta} onChange={(e) => cambiar(f.id, 'cuenta', e.target.value)}>
              <option value="efectivo">$ efectivo</option><option value="binance">$ Binance</option><option value="bs">Bs</option>
            </select>
          </Campo>
          <Campo label={`Monto (${moneda(f.cuenta)})`}><input type="number" min="0" step="0.01" value={f.monto} onChange={(e) => cambiar(f.id, 'monto', e.target.value)} /></Campo>
          {f.cuenta === 'bs' && <Campo label="Tasa BCV que pagó" ayuda={num(f.tasa_bcv) > 0 ? `= ${usd(num(f.monto) / num(f.tasa_bcv))}` : 'Falta la tasa'}><input type="number" min="0" step="0.01" value={f.tasa_bcv} onChange={(e) => cambiar(f.id, 'tasa_bcv', e.target.value)} /></Campo>}
          <button className="primario" onClick={() => guardarCobro(f)}>Guardar</button>
          <button onClick={() => borrarCobro(f)} aria-label="Eliminar cobro">🗑️</button>
        </div>
      ))}
      <div className="form">
        <Campo label="Nuevo cobro · fecha"><input type="date" value={nuevo.fecha} onChange={(e) => setNuevo({ ...nuevo, fecha: e.target.value })} /></Campo>
        <Campo label="Cuenta">
          <select value={nuevo.cuenta} onChange={(e) => setNuevo({ ...nuevo, cuenta: e.target.value })}>
            <option value="efectivo">$ efectivo</option><option value="binance">$ Binance</option><option value="bs">Bs</option>
          </select>
        </Campo>
        <Campo label={`Monto (${moneda(nuevo.cuenta)})`}><input type="number" min="0" step="0.01" value={nuevo.monto} onChange={(e) => setNuevo({ ...nuevo, monto: e.target.value })} /></Campo>
        {nuevo.cuenta === 'bs' && <Campo label="Tasa BCV que pagó"><input type="number" min="0" step="0.01" value={nuevo.tasa_bcv} onChange={(e) => setNuevo({ ...nuevo, tasa_bcv: e.target.value })} /></Campo>}
        <button onClick={agregarCobro}>Agregar cobro</button>
      </div>
      <Aviso {...msg} />
      <button onClick={cerrar}>Cerrar edición</button>
    </div>
  )
}

// Busca cuentas que no cuadran y las lista para revisarlas una por una
function revisar(filas) {
  const out = []
  const add = (c, tipo, texto) => out.push({ key: c.key, cliente: c.nombre, tipo, texto })
  filas.forEach((c) => {
    c.lineas.forEach((l) => {
      const f = String(l.fecha).slice(0, 10)
      if (num(l.cobrado_usd) - num(l.valor_usd) > 0.01) add(c, 'Abono de más', `${l.nombre} (${f}): pagó ${usd(l.cobrado_usd)} de ${usd(l.valor_usd)}. Si sobra, pásalo a otra compra.`)
      if (num(l.precio_unit) === 0) add(c, 'Precio en 0', `${l.nombre} (${f}) está en $0 y se muestra como pagada.`)
      l.abonos.forEach((a) => {
        if (a.cuenta === 'bs' && !a.propia) add(c, 'Bs sin tasa', `${l.nombre} (${f}): abono de ${num(a.monto).toLocaleString('es-VE')} Bs sin tasa propia; se valoró con la tasa de la venta (${num(a.tasa_usada)}) = ${usd(a.eq)}.`)
        if (a.cuenta === 'bs' && a.propia && num(l.tasa_bcv) > 0 && Math.abs(a.tasa_usada / num(l.tasa_bcv) - 1) > 0.2) add(c, 'Tasa rara', `${l.nombre}: abono a tasa ${num(a.tasa_usada)} y la venta tenía ${num(l.tasa_bcv)}. ¿Está bien escrita?`)
        if (String(a.fecha).slice(0, 10) < f) add(c, 'Fecha', `${l.nombre}: el abono del ${String(a.fecha).slice(0, 10)} es anterior a la venta (${f}).`)
      })
    })
  })
  // Posibles clientes repetidos: mismo nombre de pila y uno contiene al otro
  const ts = (c) => c.key.split(' ').filter((w) => w.length > 2)
  for (let i = 0; i < filas.length; i++) for (let j = i + 1; j < filas.length; j++) {
    const a = ts(filas[i]), b = ts(filas[j]); if (!a.length || !b.length) continue
    const [menor, mayor] = a.length <= b.length ? [a, b] : [b, a]
    if (menor.every((w) => mayor.includes(w)) && (filas[i].lineas.length || filas[j].lineas.length)) add(filas[i], 'Nombre repetido', `"${filas[i].nombre}" y "${filas[j].nombre}" podrían ser la misma persona; sus deudas se ven separadas. Escribe el mismo nombre (o el mismo teléfono) en ambos.`)
  }
  return out
}

function Revision({ items, abrir }) {
  const [ver, setVer] = useState(false)
  if (!items.length) return <Aviso ok="Revisión de cuentas: no encontré abonos raros ni clientes repetidos." />
  return (
    <Seccion titulo={`Revisión de cuentas (${items.length} por mirar)`} ayuda="Cosas que pueden hacer que un cliente salga mal: abonos de más, pagos en Bs sin tasa, fechas raras o nombres repetidos. Toca una fila para abrir al cliente.">
      <button onClick={() => setVer(!ver)}>{ver ? 'Ocultar' : 'Mostrar'} la lista</button>
      {ver && (
        <div className="tabla-wrap">
          <table className="clickable">
            <thead><tr><th>Cliente</th><th>Qué pasa</th><th>Detalle</th></tr></thead>
            <tbody>{items.map((it, i) => (
              <tr key={i} onClick={() => abrir(it.key)}><td><b>{it.cliente}</b></td><td><Insignia tono="warn">{it.tipo}</Insignia></td><td>{it.texto}</td></tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </Seccion>
  )
}
