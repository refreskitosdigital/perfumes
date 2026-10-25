import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Aviso, Guia, Insignia, Tarjeta } from '../ui.jsx'
import LineasEditor, { lineasParaRpc, SociosEditor, sociosParaRpc, sociosIniciales } from './LineasEditor.jsx'
import { hoy, usd, bs, num, cajaUsd } from '../lib.js'

export default function Agenda() {
  const { recargarPerfumes, socios } = useApp()
  const ped = useQuery(() => supabase.from('agenda_pedidos').select('*').order('registrado').order('codigo'), [])
  const lin = useQuery(() => supabase.from('agenda_lineas').select('*').order('id'), [])
  const ags = useQuery(() => supabase.from('agenda_socios').select('*'), [])
  const [sel, setSel] = useState(null)
  const [f, setF] = useState({ codigo: '', fecha_prevista: '', proveedor: '', envio: 0 })
  const [lineas, setLineas] = useState([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const siguiente = 'A-' + String(ped.data.length + 1).padStart(3, '0')

  const guardar = async (e) => {
    e.preventDefault()
    const codigo = f.codigo || siguiente
    const items = lineasParaRpc(lineas)
    const merc = items.reduce((a, l) => a + l.unidades * l.costo_unitario, 0)
    const reparto = sociosParaRpc(sel || sociosIniciales(socios), socios, merc + num(f.envio))
    if (!reparto.length) return setMsg({ error: 'Elige al menos un socio.', ok: '' })
    if (!items.length) return setMsg({ error: 'Agrega al menos un perfume.', ok: '' })
    const { error } = await supabase.from('agenda_pedidos').insert({
      codigo, fecha_prevista: f.fecha_prevista || null, proveedor: f.proveedor || null, envio: num(f.envio),
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    const { error: e2 } = await supabase.from('agenda_lineas').insert(items.map((l) => ({ codigo, ...l })))
    if (e2) return setMsg({ error: e2.message, ok: '' })
    const { error: e3 } = await supabase.from('agenda_socios').insert(reparto.map((r) => ({ codigo, socio: r.socio, aporte: r.aporte })))
    if (e3) return setMsg({ error: e3.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${codigo} guardado en la agenda. No cuenta en inventario ni compras hasta que pulses Realizar pedido.` })
    setF({ codigo: '', fecha_prevista: '', proveedor: '', envio: 0 })
    setLineas([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
    setSel(null)
    ped.recargar(); lin.recargar(); ags.recargar()
  }

  const [realizando, setRealizando] = useState(null)
  const terminar = (texto) => {
    setMsg({ error: '', ok: texto }); setRealizando(null)
    ped.recargar(); recargarPerfumes()
  }

  const borrar = async (p) => {
    if (!window.confirm(`¿Eliminar ${p.codigo} de la Agenda?`)) return
    await supabase.from('agenda_pedidos').delete().eq('codigo', p.codigo)
    ped.recargar(); lin.recargar()
  }

  return (
    <>
      <Guia><b>Primero planeas, después compras.</b> Lo que anotes aquí no suma en Inventario ni en Compras ni toca la plata. Cuando se haga la compra de verdad, pulsa <b>Realizar pedido</b>: ahí eliges de dónde sale el dinero (caja, un socio o un préstamo).</Guia>
      <Seccion titulo="Planear un pedido" ayuda="Anota lo que piensas comprar. Puedes editarlo o eliminarlo sin que afecte nada.">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Código"><input value={f.codigo} placeholder={siguiente} onChange={(e) => setF({ ...f, codigo: e.target.value })} /></Campo>
            <Campo label="Fecha prevista"><input type="date" value={f.fecha_prevista} onChange={(e) => setF({ ...f, fecha_prevista: e.target.value })} /></Campo>
            <Campo label="Proveedor"><input value={f.proveedor} onChange={(e) => setF({ ...f, proveedor: e.target.value })} /></Campo>
            <Campo label="Envío $"><input type="number" step="0.01" min="0" value={f.envio} onChange={(e) => setF({ ...f, envio: e.target.value })} /></Campo>
          </div>
          <LineasEditor lineas={lineas} setLineas={setLineas} envio={f.envio} />
          <SociosEditor sel={sel || sociosIniciales(socios)} setSel={setSel} inversion={lineas.reduce((a, l) => a + num(l.unidades) * num(l.costo_unitario), 0) + num(f.envio)} />
          <button className="primario" type="submit">Guardar en la agenda</button>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Pedidos en la agenda" ayuda="Los pendientes por comprar están arriba.">
        <Aviso error={ped.error || lin.error || ags.error} />
        {!ped.data.length && <p className="vacio">No hay pedidos agendados.</p>}
        {ped.data.map((p) => {
          const items = lin.data.filter((l) => l.codigo === p.codigo)
          const merc = items.reduce((a, l) => a + l.unidades * l.costo_unitario, 0)
          return (
            <article key={p.codigo} className={'pedido ' + (p.registrado ? 'hecho' : '')}>
              <header>
                <div><b>{p.codigo}</b> · {p.proveedor || 'sin proveedor'} · {p.fecha_prevista || 'sin fecha'} · Socios: {ags.data.filter((x) => x.codigo === p.codigo).map((x) => x.socio).join(', ') || '—'}</div>
                <div>Mercancía {usd(merc)} + envío {usd(p.envio)} = <b>{usd(merc + num(p.envio))}</b></div>
                {p.registrado
                  ? <Insignia tono="ok">Ya realizado</Insignia>
                  : <span><button className="primario" onClick={() => setRealizando(realizando === p.codigo ? null : p.codigo)}>🛒 Realizar pedido</button> <button onClick={() => borrar(p)}>Eliminar</button></span>}
              </header>
              {realizando === p.codigo && (
                <RealizarPedido p={p} total={merc + num(p.envio)} unidades={items.reduce((a, l) => a + l.unidades, 0)}
                  socios={socios} cancelar={() => setRealizando(null)} terminar={terminar} onError={(error) => setMsg({ error, ok: '' })} />
              )}
              {p.nota && <p className="nota-agenda">📝 {p.nota}</p>}
              <ul>{items.map((l) => <li key={l.id}>{l.nombre} · {l.unidades} u · costo {usd(l.costo_unitario)}{l.precio_detal ? ` · venta ${usd(l.precio_detal)}` : ''}</li>)}</ul>
            </article>
          )
        })}
      </Seccion>
    </>
  )
}


// Panel para pagar y realizar un pedido de la agenda
function RealizarPedido({ p, total, unidades, socios, cancelar, terminar, onError }) {
  const { tasa } = useApp()
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const pre = useQuery(() => supabase.from('prestamos').select('monto,devuelto'), [])
  const tb = num(tasa?.binance)
  const [fecha, setFecha] = useState(hoy())
  const [usar, setUsar] = useState({ binance: '', efectivo: '', bs: '' })
  const [puestos, setPuestos] = useState({})
  const [prestamista, setPrestamista] = useState('REFRESKITO Digital')
  const [despues, setDespues] = useState(false)
  const [enviando, setEnviando] = useState(false)

  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)
  const maxUsd = (c) => (c === 'bs' ? (tb > 0 ? saldo('bs') / tb : 0) : saldo(c))
  // Bs que salen de la cuenta (nunca más de lo que hay)
  const montoCuenta = (c) => {
    const u = Math.min(num(usar[c]), maxUsd(c))
    return c === 'bs' ? Math.min(Math.round(u * tb * 100) / 100, saldo('bs')) : Math.round(u * 100) / 100
  }
  const usdCuenta = (c) => (c === 'bs' ? (tb > 0 ? montoCuenta('bs') / tb : 0) : montoCuenta(c))
  const deCaja = ['binance', 'efectivo', 'bs'].reduce((a, c) => a + usdCuenta(c), 0)
  const deSocios = socios.reduce((a, s) => a + num(puestos[s]), 0)
  const prestamo = Math.round((total - deCaja - deSocios) * 100) / 100
  const deudaActual = pre.data.reduce((a, r) => a + num(r.monto) - num(r.devuelto), 0)
  const disponible = cajaUsd(caja.data, tb)

  const usarCajaPrimero = () => {
    let falta = total; const n = { binance: '', efectivo: '', bs: '' }
    for (const c of ['efectivo', 'binance', 'bs']) {
      const t = Math.min(maxUsd(c), falta)
      if (t > 0.004) { n[c] = c === 'bs' ? String(Math.floor(t * 100) / 100) : t.toFixed(2); falta -= t }
    }
    setUsar(n)
  }

  const confirmar = async () => {
    if (!despues && prestamo < -0.01) return onError(`Estás poniendo ${usd(-prestamo)} de más. Baja algún monto.`)
    if (!despues && prestamo > 0.01 && !prestamista.trim()) return onError('Escribe quién presta el dinero que falta.')
    const caja_ = ['binance', 'efectivo', 'bs'].filter((c) => montoCuenta(c) > 0).map((c) => ({ cuenta: c, monto: montoCuenta(c), usd: Math.round(usdCuenta(c) * 100) / 100 }))
    const socios_ = socios.filter((s) => num(puestos[s]) > 0).map((s) => ({ socio: s, monto: num(puestos[s]) }))
    setEnviando(true)
    const { error } = await supabase.rpc('realizar_pedido', {
      p_codigo: p.codigo, p_fecha: fecha, p_caja: despues ? [] : caja_, p_socios: despues ? [] : socios_,
      p_prestamo: despues ? 0 : Math.max(prestamo, 0), p_prestamista: prestamista, p_pagar_despues: despues,
    })
    setEnviando(false)
    if (error) return onError(error.message)
    terminar(despues
      ? `Pedido ${p.codigo} realizado. El pago al proveedor (${usd(total)}) quedó pendiente en Pagos.`
      : `Pedido ${p.codigo} realizado: ${unidades} perfumes ya están en Compras e Inventario y el pago quedó en el historial de Pagos.`)
  }

  return (
    <div className="realizar">
      <h3>Realizar {p.codigo}: {unidades} perfumes por {usd(total)}</h3>
      <Aviso error={caja.error || pre.error} />
      <div className="form">
        <Campo label="Fecha de la compra"><input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} required /></Campo>
        <label className="check"><input type="checkbox" checked={despues} onChange={(e) => setDespues(e.target.checked)} /> Todavía no le pago al proveedor (queda como pago pendiente)</label>
      </div>

      {!despues && (
        <>
          <h4>1. Dinero de la caja <small>(disponible {usd(disponible)})</small></h4>
          <div className="atajos"><button type="button" onClick={usarCajaPrimero}>Usar la caja primero</button><button type="button" onClick={() => setUsar({ binance: '', efectivo: '', bs: '' })}>Limpiar</button></div>
          <div className="form">
            {[['binance', 'Binance'], ['efectivo', 'Efectivo'], ['bs', 'Bolívares']].map(([c, n]) => (
              <Campo key={c} label={`Usar de ${n} ($)`} ayuda={`Hay ${c === 'bs' ? bs(saldo('bs')) + ' (' + usd(maxUsd('bs')) + ')' : usd(saldo(c))}`}>
                <input type="number" step="0.01" min="0" max={maxUsd(c)} value={usar[c]} onChange={(e) => setUsar({ ...usar, [c]: e.target.value })} disabled={c === 'bs' && !tb} />
              </Campo>
            ))}
          </div>

          <h4>2. Dinero que pone un socio directamente <small>(efectivo de su bolsillo)</small></h4>
          <div className="form">
            {socios.map((s) => (
              <Campo key={s} label={`${s} pone ($)`}><input type="number" step="0.01" min="0" value={puestos[s] ?? ''} onChange={(e) => setPuestos({ ...puestos, [s]: e.target.value })} /></Campo>
            ))}
          </div>

          <h4>3. Lo que falta se pide prestado</h4>
          <div className="form">
            <Campo label="Préstamo necesario ($)"><input readOnly value={Math.max(prestamo, 0).toFixed(2)} /></Campo>
            <Campo label="¿Quién presta?"><input value={prestamista} onChange={(e) => setPrestamista(e.target.value)} /></Campo>
          </div>
        </>
      )}

      <div className="cobro">
        <div><span>Total del pedido</span><b>{usd(total)}</b></div>
        {!despues && <div><span>De la caja</span><b>{usd(deCaja)}</b></div>}
        {!despues && <div><span>De los socios</span><b>{usd(deSocios)}</b></div>}
        {!despues && <div><span>Préstamo nuevo</span><b className={prestamo > 0.01 ? 'alerta' : ''}>{usd(Math.max(prestamo, 0))}</b></div>}
        {!despues && <div><span>Deuda total después</span><b>{usd(deudaActual + Math.max(prestamo, 0))}</b></div>}
        {!despues && <div><span>Quedará en caja</span><b>{usd(disponible - deCaja)}</b></div>}
      </div>
      {!despues && prestamo < -0.01 && <Aviso error={`Estás poniendo ${usd(-prestamo)} de más que el total del pedido.`} />}

      <div className="atajos">
        <button className="primario" onClick={confirmar} disabled={enviando || (!despues && prestamo < -0.01)}>{enviando ? 'Registrando…' : '✅ Confirmar y realizar pedido'}</button>
        <button onClick={cancelar}>Cancelar</button>
      </div>
    </div>
  )
}
