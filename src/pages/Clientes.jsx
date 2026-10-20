import React, { useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Tarjeta, Aviso, Guia, Insignia } from '../ui.jsx'
import { usd, num, normNombre, waLink } from '../lib.js'

const MEDALLA = ['🥇', '🥈', '🥉']

export default function Clientes() {
  const cli = useQuery(() => supabase.from('clientes').select('*').order('nombre'), [])
  const ven = useQuery(() => supabase.from('ventas_v')
    .select('id,fecha,cliente,nombre,unidades,valor_usd,cobrado_usd,pendiente_usd,vence,vendedor').order('fecha', { ascending: false }).limit(5000), [])
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

      {actual && <Detalle key={actual.key} c={actual} cerrar={() => setSel(null)} recargar={cli.recargar} />}

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

function Detalle({ c, cerrar, recargar }) {
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
          <thead><tr><th>Fecha</th><th>Perfume</th><th className="num">Unid.</th><th className="num">Valor</th><th className="num">Pagado</th><th className="num">Debe</th><th>Vendió</th></tr></thead>
          <tbody>
            {c.lineas.map((l) => (
              <tr key={l.id}>
                <td>{l.fecha}</td><td>{l.nombre}</td><td className="num">{l.unidades}</td>
                <td className="num">{usd(l.valor_usd)}</td><td className="num">{usd(l.cobrado_usd)}</td>
                <td className="num">{num(l.pendiente_usd) > 0.01 ? <b className="alerta">{usd(l.pendiente_usd)}</b> : '—'}</td>
                <td>{l.vendedor}</td>
              </tr>
            ))}
            {!c.lineas.length && <tr><td colSpan={7} className="vacio">Este cliente todavía no tiene compras.</td></tr>}
          </tbody>
        </table>
      </div>
    </Seccion>
  )
}
