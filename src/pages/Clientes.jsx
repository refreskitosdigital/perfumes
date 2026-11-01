import React, { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Tarjeta, Aviso, Guia, Insignia } from '../ui.jsx'
import { usd, num, normNombre, waLink } from '../lib.js'

const MEDALLA = ['🥇', '🥈', '🥉']

export default function Clientes() {
  const cli = useQuery(() => supabase.from('clientes').select('*').order('nombre'), [])
  const ven = useQuery(() => supabase.from('ventas_v')
    .select('id,fecha,cliente,nombre,unidades,precio_unit,base,valor_usd,cobrado_usd,pendiente_usd,vence,vendedor').order('fecha', { ascending: false }).limit(5000), [])
  const [anio, setAnio] = useState('todos')
  const [buscar, setBuscar] = useState('')
  const [sel, setSel] = useState(null)
  const [nuevo, setNuevo] = useState({ nombre: '', telefono: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const anios = useMemo(() => [...new Set(ven.data.map((v) => String(v.fecha).slice(0, 4)))].sort().reverse(), [ven.data])

  // Agrupa todas las ventas de un mismo cliente (sin importar mayúsculas ni tildes)
  const filas = useMemo(() => {
    const mapa = new Map()
    const get = (nombre, base) => {
      const k = normNombre(nombre)
      if (!mapa.has(k)) mapa.set(k, { key: k, id: null, nombre, telefono: '', notas: '', dias: new Set(), unidades: 0, total: 0, cobrado: 0, debe: 0, ultima: '', lineas: [], ...base })
      return mapa.get(k)
    }
    cli.data.forEach((c) => get(c.nombre, { id: c.id, nombre: c.nombre, telefono: c.telefono || '', notas: c.notas || '' }))
    ven.data.forEach((v) => {
      const c = get(v.cliente, {})
      c.lineas.push(v)
      c.debe += Math.max(num(v.pendiente_usd), 0)           // la deuda siempre es la total, sin importar el año
      if (anio !== 'todos' && String(v.fecha).slice(0, 4) !== anio) return
      c.dias.add(v.fecha); c.unidades += num(v.unidades); c.total += num(v.valor_usd); c.cobrado += num(v.cobrado_usd)
      if (v.fecha > c.ultima) c.ultima = v.fecha
    })
    const arr = [...mapa.values()].sort((a, b) => b.total - a.total || a.nombre.localeCompare(b.nombre))
    arr.forEach((c, i) => { c.puesto = c.total > 0 ? i + 1 : null; c.compras = c.dias.size })
    return arr
  }, [cli.data, ven.data, anio])

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
      <Aviso error={cli.error || ven.error} {...msg} />

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
        acciones={<input className="buscador" placeholder="🔍 Buscar por nombre o teléfono" value={buscar} onChange={(e) => setBuscar(e.target.value)} />}>
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

      {actual && <Detalle key={actual.key} c={actual} cerrar={() => setSel(null)} recargar={cli.recargar} recargarVentas={ven.recargar} />}

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

  const guardar = async () => {
    const datos = { telefono: tel.trim() || null, notas: notas.trim() || null }
    const r = c.id
      ? await supabase.from('clientes').update(datos).eq('id', c.id)
      : await supabase.from('clientes').insert({ nombre: c.nombre, ...datos })
    setMsg(r.error ? { error: r.error.message, ok: '' } : { error: '', ok: 'Datos guardados.' })
    if (!r.error) recargar()
  }

  return (
    <Seccion titulo={`Historial de ${c.nombre}`} acciones={<button onClick={cerrar}>Cerrar ✕</button>}>
      <div className="tarjetas">
        <Tarjeta titulo="Ha comprado" valor={usd(c.total)} nota={`${c.unidades} perfumes en ${c.compras} ${c.compras === 1 ? 'compra' : 'compras'}`} />
        <Tarjeta titulo="Ha pagado" valor={usd(c.cobrado)} tono="bueno" />
        <Tarjeta titulo="Debe" valor={usd(c.debe)} tono={c.debe > 0.01 ? 'malo' : ''} />
        <Tarjeta titulo="Puesto en el ranking" valor={c.puesto ? '#' + c.puesto : '—'} />
      </div>
      <div className="form" style={{ marginTop: 12 }}>
        <Campo label="Teléfono"><input value={tel} onChange={(e) => setTel(e.target.value)} placeholder="0414-1234567" /></Campo>
        <Campo label="Notas (gustos, fechas, etc.)"><input value={notas} onChange={(e) => setNotas(e.target.value)} /></Campo>
        <button className="primario" onClick={guardar}>Guardar datos</button>
        {c.debe > 0.01 && enlace && <a className="boton-link" href={enlace} target="_blank" rel="noreferrer">💬 Recordar el pago por WhatsApp</a>}
      </div>
      <Aviso {...msg} />
      <h3>Todo lo que ha comprado</h3>
      <div className="tabla-wrap">
        <table>
          <thead><tr><th>Fecha</th><th>Perfume</th><th className="num">Unid.</th><th className="num">Valor</th><th className="num">Pagado</th><th className="num">Debe</th><th>Vendió</th><th /></tr></thead>
          <tbody>
            {c.lineas.flatMap((l) => [
              <tr key={l.id}>
                <td>{l.fecha}</td><td>{l.nombre}</td><td className="num">{l.unidades}</td>
                <td className="num">{usd(l.valor_usd)}</td><td className="num">{usd(l.cobrado_usd)}</td>
                <td className="num">{num(l.pendiente_usd) > 0.01 ? <b className="alerta">{usd(l.pendiente_usd)}</b> : '—'}</td>
                <td>{l.vendedor}</td>
                <td><button onClick={() => setEditando(editando === l.id ? null : l.id)} aria-label="Editar venta y cobros">✏️</button></td>
              </tr>,
              editando === l.id && <tr key={'e' + l.id}><td colSpan={8}><EditarVenta l={l} listo={() => { recargarVentas() }} cerrar={() => setEditando(null)} /></td></tr>,
            ])}
            {!c.lineas.length && <tr><td colSpan={8} className="vacio">Este cliente todavía no tiene compras.</td></tr>}
          </tbody>
        </table>
      </div>
    </Seccion>
  )
}

// Corrige una venta (fecha, unidades, precio) y los cobros que ya se registraron (monto, fecha, cuenta, tasa)
function EditarVenta({ l, listo, cerrar }) {
  const cobros = useQuery(() => supabase.from('cobros').select('*').eq('venta_id', l.id).order('fecha').order('id'), [l.id])
  const [v, setV] = useState({ fecha: String(l.fecha).slice(0, 10), unidades: l.unidades, precio_unit: l.precio_unit })
  const [nuevo, setNuevo] = useState({ fecha: String(l.fecha).slice(0, 10), cuenta: 'efectivo', monto: '', tasa_binance: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [filas, setFilas] = useState([])
  useEffect(() => { setFilas(cobros.data.map((c) => ({ ...c, fecha: String(c.fecha).slice(0, 10), tasa_binance: c.tasa_binance ?? '' }))) }, [cobros.data])
  const moneda = (c) => (c === 'bs' ? 'Bs' : '$')
  const fin = (r) => { if (r.error) setMsg({ error: r.error.message, ok: '' }); else { setMsg({ error: '', ok: 'Guardado.' }); cobros.recargar(); listo() } }

  const guardarVenta = async () => {
    if (!(num(v.unidades) >= 1) || num(v.precio_unit) < 0) return setMsg({ error: 'Revisa las unidades y el precio.', ok: '' })
    fin(await supabase.from('ventas').update({ fecha: v.fecha, unidades: Math.round(num(v.unidades)), precio_unit: num(v.precio_unit) }).eq('id', l.id))
  }
  const cambiar = (id, k, val) => setFilas((fs) => fs.map((f) => (f.id === id ? { ...f, [k]: val } : f)))
  const guardarCobro = async (f) => {
    if (!(num(f.monto) > 0)) return setMsg({ error: 'El monto del cobro debe ser mayor a 0.', ok: '' })
    fin(await supabase.from('cobros').update({ fecha: f.fecha, cuenta: f.cuenta, monto: num(f.monto), tasa_binance: f.cuenta === 'bs' && num(f.tasa_binance) > 0 ? num(f.tasa_binance) : null }).eq('id', f.id))
  }
  const borrarCobro = async (f) => {
    if (!window.confirm(`¿Eliminar el cobro de ${moneda(f.cuenta)} ${num(f.monto).toLocaleString('es-VE')} del ${f.fecha}?`)) return
    fin(await supabase.from('cobros').delete().eq('id', f.id))
  }
  const agregarCobro = async () => {
    if (!(num(nuevo.monto) > 0)) return setMsg({ error: 'Escribe el monto del cobro.', ok: '' })
    const r = await supabase.from('cobros').insert({ venta_id: l.id, fecha: nuevo.fecha, cuenta: nuevo.cuenta, monto: num(nuevo.monto), tasa_binance: nuevo.cuenta === 'bs' && num(nuevo.tasa_binance) > 0 ? num(nuevo.tasa_binance) : null })
    fin(r); if (!r.error) setNuevo({ ...nuevo, monto: '', tasa_binance: '' })
  }

  return (
    <div className="editar-venta">
      <h4>Corregir venta: {l.nombre}</h4>
      <div className="form">
        <Campo label="Fecha"><input type="date" value={v.fecha} onChange={(e) => setV({ ...v, fecha: e.target.value })} /></Campo>
        <Campo label="Unidades"><input type="number" min="1" step="1" value={v.unidades} onChange={(e) => setV({ ...v, unidades: e.target.value })} /></Campo>
        <Campo label={`Precio por unidad (${l.base === 'bcv' ? 'BCV$' : '$'})`}><input type="number" min="0" step="0.01" value={v.precio_unit} onChange={(e) => setV({ ...v, precio_unit: e.target.value })} /></Campo>
        <button className="primario" onClick={guardarVenta}>Guardar venta</button>
      </div>
      <p className="ayuda">Total de la venta: <b>{usd(num(v.unidades) * num(v.precio_unit))}{l.base === 'bcv' ? ' BCV$' : ''}</b>. Si cambias las unidades, el inventario se ajusta solo.</p>
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
          {f.cuenta === 'bs' && <Campo label="Tasa Binance" ayuda="Vacío = la de la venta"><input type="number" min="0" step="0.01" value={f.tasa_binance} onChange={(e) => cambiar(f.id, 'tasa_binance', e.target.value)} /></Campo>}
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
        {nuevo.cuenta === 'bs' && <Campo label="Tasa Binance"><input type="number" min="0" step="0.01" value={nuevo.tasa_binance} onChange={(e) => setNuevo({ ...nuevo, tasa_binance: e.target.value })} /></Campo>}
        <button onClick={agregarCobro}>Agregar cobro</button>
      </div>
      <Aviso {...msg} />
      <button onClick={cerrar}>Cerrar edición</button>
    </div>
  )
}
