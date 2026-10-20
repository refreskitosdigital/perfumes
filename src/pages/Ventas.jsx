import React, { useEffect, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Aviso } from '../ui.jsx'
import { hoy, usd, bs, num, pct, precioPorCantidad, precioDivisa, precioBs, valorVenta, cobradoUsd, descuentoMax } from '../lib.js'

const vacia = (vendedor) => ({
  fecha: hoy(), cliente: '', vendedor: vendedor || '', perfume_id: '', pedido: '', unidades: 1, precio_unit: '',
  base: 'divisa', vence: '', pago_bs: '', pago_efectivo: '', pago_binance: '', nota: '',
})

export default function Ventas() {
  const { perfumes, tasa, config, miSocio, socios } = useApp()
  const ventas = useQuery(() => supabase.from('ventas_v').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }).limit(300), [])
  const stock = useQuery(() => supabase.from('stock_pedido_v').select('*').order('fecha').order('pedido_codigo'), [])
  const [f, setF] = useState(vacia(miSocio?.nombre))
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const perfume = perfumes.data.find((p) => String(p.id) === String(f.perfume_id))
  const origenes = stock.data.filter((s) => String(s.perfume_id) === String(f.perfume_id) && s.restante > 0)

  // Al elegir perfume: propone el precio y el pedido más antiguo con unidades disponibles
  useEffect(() => {
    if (!perfume) return
    setF((x) => ({
      ...x,
      precio_unit: precioPorCantidad(perfume, x.unidades, config.umbral_mayor) || '',
      pedido: origenes.length ? origenes[0].pedido_codigo : '',
    }))
  }, [f.perfume_id, f.unidades, perfumes.data, stock.data]) // eslint-disable-line

  if (!tasa) return <Seccion titulo="Ventas"><p className="vacio">Primero registra la tasa de hoy en la pestaña Tasas.</p></Seccion>

  const total = num(f.unidades) * num(f.precio_unit)
  const valor = valorVenta(f.base, total, tasa.bcv, tasa.binance)
  const cobrado = cobradoUsd({ bs: f.pago_bs, efectivo: f.pago_efectivo, binance: f.pago_binance }, tasa.binance)
  const pendiente = valor - cobrado
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })
  const llenar = (campo, v) => setF({ ...f, pago_bs: '', pago_efectivo: '', pago_binance: '', [campo]: v.toFixed(2) })

  const guardar = async (e) => {
    e.preventDefault()
    if (pendiente > 0.01 && !f.vence && !window.confirm(`Queda ${usd(pendiente)} por cobrar y no pusiste fecha de pago. ¿Guardar igual?`)) return
    if (pendiente < -0.01 && !window.confirm(`Cobraste ${usd(-pendiente)} más que el valor de la venta. ¿Guardar igual?`)) return
    const { data, error } = await supabase.from('ventas').insert({
      fecha: f.fecha, cliente: f.cliente, vendedor: f.vendedor, perfume_id: Number(f.perfume_id),
      pedido_codigo: f.pedido || null, unidades: Number(f.unidades), precio_unit: num(f.precio_unit), base: f.base,
      tasa_bcv: tasa.bcv, tasa_binance: tasa.binance, vence: f.vence || null, nota: f.nota || null,
    }).select('id').single()
    if (error) return setMsg({ error: error.message, ok: '' })
    const cobros = [['bs', f.pago_bs], ['efectivo', f.pago_efectivo], ['binance', f.pago_binance]]
      .filter(([, m]) => num(m) > 0).map(([cuenta, m]) => ({ venta_id: data.id, fecha: f.fecha, cuenta, monto: num(m) }))
    if (cobros.length) {
      const { error: e2 } = await supabase.from('cobros').insert(cobros)
      if (e2) return setMsg({ error: 'La venta se guardó pero falló el cobro: ' + e2.message, ok: '' })
    }
    setMsg({ error: '', ok: pendiente > 0.01 ? `Venta registrada. Quedan ${usd(pendiente)} por cobrar.` : 'Venta registrada.' })
    setF(vacia(f.vendedor))
    ventas.recargar(); stock.recargar()
  }

  return (
    <>
      <Seccion titulo="Registrar venta" ayuda="Cada venta sale de un pedido (el más antiguo con stock, por defecto) para repartir la ganancia entre sus socios. Si no hay stock queda como venta anticipada.">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Fecha"><input type="date" value={f.fecha} onChange={set('fecha')} required /></Campo>
            <Campo label="Cliente"><input value={f.cliente} onChange={set('cliente')} required /></Campo>
            <Campo label="Vendedor">
              <select value={f.vendedor} onChange={set('vendedor')} required>
                <option value="">Elegir…</option>
                {socios.map((n) => <option key={n}>{n}</option>)}
              </select>
            </Campo>
            <Campo label="Perfume">
              <select value={f.perfume_id} onChange={set('perfume_id')} required>
                <option value="">Elegir…</option>
                {perfumes.data.map((p) => <option key={p.id} value={p.id}>{p.sku} · {p.nombre}</option>)}
              </select>
            </Campo>
            <Campo label="Sale del pedido" ayuda={perfume && !origenes.length ? 'Sin stock: venta anticipada' : ''}>
              <select value={f.pedido} onChange={set('pedido')}>
                <option value="">Sin pedido (anticipada)</option>
                {origenes.map((s) => <option key={s.pedido_codigo} value={s.pedido_codigo}>{s.pedido_codigo} · quedan {s.restante}</option>)}
              </select>
            </Campo>
            <Campo label="Unidades" ayuda={`Al mayor desde ${config.umbral_mayor}`}><input type="number" min="1" value={f.unidades} onChange={set('unidades')} required /></Campo>
            <Campo label="Precio unit. $"><input type="number" step="0.01" min="0" value={f.precio_unit} onChange={set('precio_unit')} required /></Campo>
            <Campo label="El precio está en" ayuda="BCV$ = se paga en Bs a tasa BCV">
              <select value={f.base} onChange={set('base')}><option value="divisa">$ divisa (real)</option><option value="bcv">BCV$ (Bs a tasa BCV)</option></select>
            </Campo>
            <Campo label="Fecha de pago del saldo"><input type="date" value={f.vence} onChange={set('vence')} /></Campo>
          </div>

          <div className="cobro">
            <div><span>Precio pactado</span><b>{usd(total)}{f.base === 'bcv' ? ' BCV$' : ''}</b></div>
            <div><span>Valor real en $ (repone a Binance)</span><b>{usd(valor)}</b></div>
            <div><span>Si paga en Bs ({tasa.bcv})</span><b>{bs(precioBs(total, tasa.bcv))}</b></div>
            <div><span>Si paga en divisa (−{pct(descuentoMax(tasa.bcv, tasa.binance))})</span><b>{usd(precioDivisa(total, tasa.bcv, tasa.binance))}</b></div>
          </div>

          <div className="form">
            <Campo label="Cobrado ahora en Bs"><input type="number" step="0.01" min="0" value={f.pago_bs} onChange={set('pago_bs')} /></Campo>
            <Campo label="Cobrado ahora $ efectivo"><input type="number" step="0.01" min="0" value={f.pago_efectivo} onChange={set('pago_efectivo')} /></Campo>
            <Campo label="Cobrado ahora $ Binance"><input type="number" step="0.01" min="0" value={f.pago_binance} onChange={set('pago_binance')} /></Campo>
            <Campo label="Nota"><input value={f.nota} onChange={set('nota')} /></Campo>
          </div>
          <div className="atajos">
            Cobrar todo en: <button type="button" onClick={() => llenar('pago_bs', valor * tasa.binance)}>Bs</button>
            <button type="button" onClick={() => llenar('pago_efectivo', valor)}>$ efectivo</button>
            <button type="button" onClick={() => llenar('pago_binance', valor)}>$ Binance</button>
            <span className={'estado ' + (Math.abs(pendiente) <= 0.01 ? 'ok' : 'falta')}>
              Cobrado {usd(cobrado)} · {Math.abs(pendiente) <= 0.01 ? 'completo' : pendiente > 0 ? `queda por cobrar ${usd(pendiente)}` : `sobra ${usd(-pendiente)}`}
            </span>
          </div>
          <button className="primario" type="submit">Registrar venta</button>
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
        ]} />
      </Seccion>
    </>
  )
}
