import React, { useEffect, useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Aviso } from '../ui.jsx'
import { hoy, usd, bs, num, precioPorCantidad, tasaVenta } from '../lib.js'

const sumarDias = (f, d) => { const [y, m, dd] = f.split('-').map(Number); return new Date(Date.UTC(y, m - 1, dd + d)).toISOString().slice(0, 10) }
const corta = (f) => { const [, m, d] = f.split('-'); return `${d}/${m}` }
const linea = () => ({ perfume_id: '', unidades: 1, precio: '', manual: false, pedido: '' })
const NOMBRES_PLAN = { todo: 'Pagó todo', mitades: 'Paga en 2 partes (50 % y 50 %)', despues: 'Paga después', parte: 'Pagó una parte' }

export default function Ventas() {
  const { perfumes, tasa, config, miSocio, socios } = useApp()
  const ventas = useQuery(() => supabase.from('ventas_v').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }).limit(300), [])
  const clientes = useQuery(() => supabase.from('clientes').select('nombre').order('nombre'), [])
  const stock = useQuery(() => supabase.from('stock_pedido_v').select('*').order('fecha').order('pedido_codigo'), [])
  const [fecha, setFecha] = useState(hoy())
  const [cliente, setCliente] = useState('')
  const [vendedor, setVendedor] = useState(miSocio?.nombre || '')
  const [lineas, setLineas] = useState([linea()])
  const [plan, setPlan] = useState('todo')
  const [cuenta, setCuenta] = useState('efectivo')
  const [parte, setParte] = useState('')
  const [fecha1, setFecha1] = useState(sumarDias(hoy(), 7))
  const [fecha2, setFecha2] = useState(sumarDias(hoy(), 22))
  const [nota, setNota] = useState('')
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [guardando, setGuardando] = useState(false)

  useEffect(() => { if (miSocio && !vendedor) setVendedor(miSocio.nombre) }, [miSocio]) // eslint-disable-line

  const unidadesTotales = lineas.reduce((a, l) => a + num(l.unidades), 0)
  const pf = (id) => perfumes.data.find((p) => String(p.id) === String(id))
  const dispPerfume = (id) => stock.data.filter((s) => String(s.perfume_id) === String(id) && s.restante > 0)
  const stockDe = (id) => dispPerfume(id).reduce((a, s) => a + s.restante, 0)

  // Propone precio (al mayor si el total de perfumes llega al umbral) y el pedido más antiguo con stock
  useEffect(() => {
    setLineas((ls) => ls.map((l) => {
      const p = pf(l.perfume_id)
      if (!p) return l
      const orig = dispPerfume(l.perfume_id)
      const cabe = orig.find((o) => o.restante >= num(l.unidades)) || orig[0]
      return {
        ...l,
        precio: l.manual ? l.precio : (precioPorCantidad(p, unidadesTotales, config.umbral_mayor) || ''),
        pedido: l.pedidoManual ? l.pedido : (cabe ? cabe.pedido_codigo : ''),
      }
    }))
  }, [lineas.map((l) => l.perfume_id + ':' + l.unidades + ':' + l.manual).join('|'), unidadesTotales, perfumes.data, stock.data]) // eslint-disable-line

  if (!tasa) return <Seccion titulo="Ventas"><p className="vacio">Primero registra la tasa de hoy en la pestaña Tasas.</p></Seccion>

  const tv = tasaVenta(tasa)   // BCV Euro: la única tasa de venta
  const totales = lineas.map((l) => num(l.unidades) * num(l.precio))
  const total = totales.reduce((a, b) => a + b, 0)
  const alMayor = unidadesTotales >= config.umbral_mayor
  const setLinea = (i, cambios) => setLineas((ls) => ls.map((l, j) => (j === i ? { ...l, ...cambios } : l)))

  // Cuánto se cobra ahora (en $) según el plan elegido
  const cobrarAhora = plan === 'todo' ? total : plan === 'parte' ? Math.min(num(parte), total) : 0
  const vence = plan === 'mitades' ? fecha1 : plan === 'despues' ? fecha1 : plan === 'parte' ? fecha1 : ''
  const textoPlan = plan === 'mitades'
    ? `Pagará 50% el ${corta(fecha1)} y 50% el ${corta(fecha2)}`
    : plan === 'despues' ? `Paga el ${corta(fecha1)}`
    : plan === 'parte' ? `Pagó ${usd(cobrarAhora)}, el resto el ${corta(fecha1)}` : ''

  const guardar = async (e) => {
    e.preventDefault()
    setMsg({ error: '', ok: '' })
    const validas = lineas.filter((l) => l.perfume_id)
    if (!validas.length) return setMsg({ error: 'Elige al menos un perfume.', ok: '' })
    if (validas.some((l) => num(l.precio) <= 0 && !window.confirm('Hay un perfume sin precio (queda en $0). ¿Guardar igual?'))) return
    if (plan === 'parte' && !(num(parte) > 0)) return setMsg({ error: 'Escribe cuánto pagó ahora.', ok: '' })
    setGuardando(true)
    const notaFinal = [textoPlan, nota.trim()].filter(Boolean).join(' · ') || null
    const filas = validas.map((l) => ({
      fecha, cliente: cliente.trim(), vendedor, perfume_id: Number(l.perfume_id),
      pedido_codigo: l.pedido || null, unidades: Number(l.unidades), precio_unit: num(l.precio), base: 'divisa',
      tasa_bcv: tv, tasa_binance: tv, vence: vence || null, nota: notaFinal,
    }))
    const { data, error } = await supabase.from('ventas').insert(filas).select('id')
    if (error) { setGuardando(false); return setMsg({ error: error.message, ok: '' }) }

    // Reparte lo cobrado entre los perfumes de la venta, en proporción a su valor
    if (cobrarAhora > 0.004) {
      const tot = validas.reduce((a, l) => a + num(l.unidades) * num(l.precio), 0) || 1
      let restante = cobrarAhora
      const cobros = data.map((v, i) => {
        const valor = num(validas[i].unidades) * num(validas[i].precio)
        const usdI = i === data.length - 1 ? restante : Math.round(((cobrarAhora * valor) / tot) * 100) / 100
        restante = Math.round((restante - usdI) * 100) / 100
        return { venta_id: v.id, fecha, cuenta, monto: cuenta === 'bs' ? Math.round(usdI * tv * 100) / 100 : usdI }
      }).filter((c) => c.monto > 0)
      if (cobros.length) {
        const { error: e2 } = await supabase.from('cobros').insert(cobros)
        if (e2) { setGuardando(false); return setMsg({ error: 'La venta se guardó pero falló el cobro: ' + e2.message, ok: '' }) }
      }
    }
    const resto = total - cobrarAhora
    setMsg({ error: '', ok: `Venta de ${usd(total)} a ${cliente.trim()} registrada.` + (resto > 0.01 ? ` Quedan ${usd(resto)} por cobrar${vence ? ' (próximo pago ' + corta(vence) + ')' : ''}.` : ' Cobrada completa.') })
    setCliente(''); setLineas([linea()]); setPlan('todo'); setParte(''); setNota('')
    setGuardando(false)
    ventas.recargar(); stock.recargar(); clientes.recargar()
  }

  const eliminar = async (v) => {
    if (!window.confirm(`¿Eliminar la venta de ${v.nombre} a ${v.cliente} (${usd(v.valor_usd)})? Se borran también sus cobros.`)) return
    const { error } = await supabase.from('ventas').delete().eq('id', v.id)
    if (error) return setMsg({ error: error.message, ok: '' })
    ventas.recargar(); stock.recargar()
  }

  return (
    <>
      <Seccion titulo="Registrar venta" ayuda="Un cliente puede llevar varios perfumes: agrégalos todos y marca cómo pagó. El precio se propone solo y el pedido también.">
        <form onSubmit={guardar} className="venta-rapida">
          <div className="form">
            <Campo label="Cliente" ayuda="Si ya compró antes, elígelo de la lista">
              <input list="lista-clientes" value={cliente} onChange={(e) => setCliente(e.target.value)} required autoComplete="off" />
              <datalist id="lista-clientes">{clientes.data.map((c) => <option key={c.nombre} value={c.nombre} />)}</datalist>
            </Campo>
            <Campo label="Vendedor">
              <select value={vendedor} onChange={(e) => setVendedor(e.target.value)} required>
                <option value="">Elegir…</option>
                {socios.map((n) => <option key={n}>{n}</option>)}
              </select>
            </Campo>
            <Campo label="Fecha"><input type="date" value={fecha} onChange={(e) => setFecha(e.target.value)} required /></Campo>
          </div>

          <div className="vl-lista">
            {lineas.map((l, i) => {
              const p = pf(l.perfume_id)
              const disp = l.perfume_id ? stockDe(l.perfume_id) : null
              const falta = p && num(l.unidades) > disp
              return (
                <div className="vl" key={i}>
                  <div className="vl-perfume">
                    <select value={l.perfume_id} onChange={(e) => setLinea(i, { perfume_id: e.target.value, manual: false, pedidoManual: false })} aria-label="Perfume">
                      <option value="">Elegir perfume…</option>
                      {perfumes.data.map((x) => <option key={x.id} value={x.id}>{x.nombre} · {stockDe(x.id) > 0 ? stockDe(x.id) + ' disp.' : 'sin stock'}</option>)}
                    </select>
                  </div>
                  <label className="vl-u"><span>Unid.</span>
                    <input type="number" min="1" inputMode="numeric" value={l.unidades} onChange={(e) => setLinea(i, { unidades: e.target.value })} required />
                  </label>
                  <label className="vl-p"><span>Precio $</span>
                    <input type="number" step="0.01" min="0" inputMode="decimal" value={l.precio} onChange={(e) => setLinea(i, { precio: e.target.value, manual: true })} required />
                  </label>
                  <div className="vl-t"><span>Total</span><b>{usd(totales[i])}</b></div>
                  {lineas.length > 1 && <button type="button" className="vl-x" onClick={() => setLineas((ls) => ls.filter((_, j) => j !== i))} aria-label="Quitar perfume">✕</button>}
                  {p && (
                    <small className={'vl-nota' + (falta || !disp ? ' aviso-s' : '')}>
                      {!disp ? 'Sin stock: queda como venta anticipada (se descuenta cuando llegue la compra).' : falta ? `Solo quedan ${disp}; el resto queda como anticipada.` : `Sale del pedido ${l.pedido || '—'}`}
                    </small>
                  )}
                </div>
              )
            })}
            <button type="button" onClick={() => setLineas((ls) => [...ls, linea()])}>➕ Agregar otro perfume</button>
          </div>

          <div className="cobro">
            <div><span>Total de la venta</span><b>{usd(total)}</b></div>
            <div><span>En Bs (tasa BCV Euro {tv.toLocaleString('es-VE')})</span><b>{bs(total * tv)}</b></div>
            <div><span>{alMayor ? '✅ Precio al mayor' : `Al mayor desde ${config.umbral_mayor} perfumes`}</span><b>{unidadesTotales} perfumes</b></div>
          </div>

          <div className="plan">
            <div className="plan-op" role="radiogroup" aria-label="Cómo paga">
              {Object.entries(NOMBRES_PLAN).map(([k, t]) => (
                <button type="button" key={k} role="radio" aria-checked={plan === k} className={plan === k ? 'on' : ''} onClick={() => setPlan(k)}>{t}</button>
              ))}
            </div>
            <div className="form">
              {(plan === 'todo' || plan === 'parte') && (
                <Campo label="Pagó en">
                  <select value={cuenta} onChange={(e) => setCuenta(e.target.value)}>
                    <option value="efectivo">$ Efectivo</option>
                    <option value="binance">$ Binance</option>
                    <option value="bs">Bs (a tasa BCV Euro)</option>
                  </select>
                </Campo>
              )}
              {plan === 'parte' && <Campo label="Monto que pagó en $" ayuda={cobrarAhora > 0 && cuenta === 'bs' ? bs(cobrarAhora * tv) : ''}><input type="number" step="0.01" min="0" inputMode="decimal" value={parte} onChange={(e) => setParte(e.target.value)} /></Campo>}
              {plan === 'mitades' && <>
                <Campo label="Primer pago (50 %)" ayuda={usd(total / 2)}><input type="date" value={fecha1} onChange={(e) => setFecha1(e.target.value)} required /></Campo>
                <Campo label="Segundo pago (50 %)" ayuda={usd(total / 2)}><input type="date" value={fecha2} onChange={(e) => setFecha2(e.target.value)} required /></Campo>
              </>}
              {(plan === 'despues' || plan === 'parte') && <Campo label={plan === 'parte' ? 'El resto lo paga el' : 'Fecha de pago'}><input type="date" value={fecha1} onChange={(e) => setFecha1(e.target.value)} required /></Campo>}
              <Campo label="Nota (opcional)"><input value={nota} onChange={(e) => setNota(e.target.value)} /></Campo>
            </div>
            <p className="plan-res">
              {plan === 'todo' && <>Se cobra <b>{usd(total)}</b> ahora. No queda nada por cobrar.</>}
              {plan === 'mitades' && <>Queda por cobrar <b>{usd(total)}</b>: {usd(total / 2)} el {corta(fecha1)} y {usd(total / 2)} el {corta(fecha2)}. Aparecerá en Por cobrar.</>}
              {plan === 'despues' && <>Queda por cobrar <b>{usd(total)}</b> para el {corta(fecha1)}.</>}
              {plan === 'parte' && <>Se cobra <b>{usd(cobrarAhora)}</b> ahora y quedan <b>{usd(Math.max(total - cobrarAhora, 0))}</b> para el {corta(fecha1)}.</>}
            </p>
          </div>
          <button className="primario" type="submit" disabled={guardando}>{guardando ? 'Guardando…' : 'Registrar venta'}</button>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Ventas recientes">
        <Aviso error={ventas.error || stock.error} />
        <Tabla filas={ventas.data} cols={[
          { k: 'fecha', t: 'Fecha' }, { k: 'cliente', t: 'Cliente' }, { k: 'vendedor', t: 'Vendedor' },
          { k: 'nombre', t: 'Perfume' }, { k: 'unidades', t: 'Unid.', num: true },
          { k: 'pedido_codigo', t: 'Pedido', f: (r) => r.pedido_codigo || 'anticipada' },
          { k: 'total_pactado', t: 'Pactado', num: true, f: (r) => usd(r.total_pactado) + (r.base === 'bcv' ? ' BCV' : '') },
          { k: 'valor_usd', t: 'Valor $', num: true, f: (r) => usd(r.valor_usd) },
          { k: 'cobrado_usd', t: 'Cobrado', num: true, f: (r) => usd(r.cobrado_usd) },
          { k: 'pendiente_usd', t: 'Pendiente', num: true, f: (r) => (r.pendiente_usd > 0.01 ? <b className="alerta">{usd(r.pendiente_usd)}</b> : '') },
          { k: 'ganancia', t: 'Ganancia', num: true, f: (r) => (r.ganancia == null ? '—' : usd(r.ganancia)) },
          { k: 'x', t: '', f: (r) => <button onClick={() => eliminar(r)} aria-label="Eliminar venta">🗑️</button> },
        ]} />
      </Seccion>
    </>
  )
}
