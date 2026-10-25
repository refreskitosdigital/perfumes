import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Tarjeta, Aviso } from '../ui.jsx'
import { hoy, usd, num } from '../lib.js'

export const CATEGORIAS = {
  delivery: '🛵 Delivery',
  traslado: '🚚 Traslado de mercancía',
  empaque: '🎁 Empaque / bolsas',
  publicidad: '📣 Publicidad',
  comision: '🤝 Comisión',
  otro: '🧾 Otro',
}

const vacio = (socio) => ({ fecha: hoy(), categoria: 'delivery', concepto: '', monto: '', pedido: '', origen: 'socio', pagado_por: socio || '' })

export default function Gastos() {
  const { socios, miSocio } = useApp()
  const gastos = useQuery(() => supabase.from('gastos').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }).limit(300), [])
  const pedidos = useQuery(() => supabase.from('pedidos').select('codigo').order('codigo'), [])
  const [f, setF] = useState(vacio(miSocio?.nombre))
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })

  const total = gastos.data.reduce((a, g) => a + num(g.monto), 0)
  const mes = hoy().slice(0, 7)
  const delMes = gastos.data.filter((g) => String(g.fecha).startsWith(mes)).reduce((a, g) => a + num(g.monto), 0)
  const porCat = Object.keys(CATEGORIAS).map((k) => [k, gastos.data.filter((g) => g.categoria === k).reduce((a, g) => a + num(g.monto), 0)]).filter(([, v]) => v > 0)

  const guardar = async (e) => {
    e.preventDefault()
    const concepto = f.concepto.trim() || CATEGORIAS[f.categoria].replace(/^\S+\s/, '')
    const { error } = await supabase.from('gastos').insert({
      fecha: f.fecha, categoria: f.categoria, concepto, monto: num(f.monto),
      pedido_codigo: f.pedido || null,
      cuenta: f.origen === 'socio' ? null : f.origen,
      pagado_por: f.origen === 'socio' ? (f.pagado_por || null) : null,
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Gasto de ${usd(f.monto)} registrado.` })
    setF({ ...vacio(miSocio?.nombre), categoria: f.categoria, pedido: f.pedido })
    gastos.recargar()
  }

  const borrar = async (g) => {
    if (!window.confirm(`¿Eliminar el gasto "${g.concepto}" de ${usd(g.monto)}?`)) return
    const { error } = await supabase.from('gastos').delete().eq('id', g.id)
    if (error) return setMsg({ error: error.message, ok: '' })
    gastos.recargar()
  }

  return (
    <>
      <Seccion titulo="Registrar un gasto" ayuda="Todo lo que cuesta mover el negocio y no es mercancía: delivery, traslados, bolsas, publicidad. Se resta de la ganancia.">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Fecha"><input type="date" value={f.fecha} onChange={set('fecha')} required /></Campo>
            <Campo label="Tipo de gasto">
              <select value={f.categoria} onChange={set('categoria')}>
                {Object.entries(CATEGORIAS).map(([k, t]) => <option key={k} value={k}>{t}</option>)}
              </select>
            </Campo>
            <Campo label="Monto en $"><input type="number" step="0.01" min="0.01" inputMode="decimal" value={f.monto} onChange={set('monto')} required /></Campo>
            <Campo label="Detalle (opcional)"><input value={f.concepto} onChange={set('concepto')} placeholder="Ej: delivery a Altamira" /></Campo>
            <Campo label="¿De qué pedido es?" ayuda="Si es de un lote, baja la ganancia de ese lote y se reparte entre sus socios.">
              <select value={f.pedido} onChange={set('pedido')}>
                <option value="">General (de todo el negocio)</option>
                {pedidos.data.map((p) => <option key={p.codigo} value={p.codigo}>{p.codigo}</option>)}
              </select>
            </Campo>
            <Campo label="¿Quién lo pagó?">
              <select value={f.origen} onChange={set('origen')}>
                <option value="socio">Lo puso un socio de su bolsillo</option>
                <option value="efectivo">Sale de la caja (efectivo)</option>
                <option value="binance">Sale de la caja (Binance)</option>
              </select>
            </Campo>
            {f.origen === 'socio' && (
              <Campo label="Socio que lo pagó">
                <select value={f.pagado_por} onChange={set('pagado_por')}>
                  <option value="">—</option>
                  {socios.map((n) => <option key={n}>{n}</option>)}
                </select>
              </Campo>
            )}
          </div>
          <button className="primario" type="submit">Guardar gasto</button>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Resumen de gastos">
        <div className="tarjetas">
          <Tarjeta titulo="Total gastado" valor={usd(total)} tono={total > 0 ? 'malo' : ''} />
          <Tarjeta titulo="Este mes" valor={usd(delMes)} />
          {porCat.map(([k, v]) => <Tarjeta key={k} titulo={CATEGORIAS[k]} valor={usd(v)} />)}
        </div>
      </Seccion>

      <Seccion titulo="Historial de gastos">
        <Aviso error={gastos.error} />
        <Tabla filas={gastos.data} vacio="Aún no hay gastos registrados." cols={[
          { k: 'fecha', t: 'Fecha' },
          { k: 'categoria', t: 'Tipo', f: (g) => CATEGORIAS[g.categoria] || g.categoria },
          { k: 'concepto', t: 'Detalle' },
          { k: 'pedido_codigo', t: 'Pedido', f: (g) => g.pedido_codigo || 'General' },
          { k: 'origen', t: 'Pagó', f: (g) => (g.cuenta ? `Caja ${g.cuenta}` : g.pagado_por || 'Un socio') },
          { k: 'monto', t: 'Monto', num: true, f: (g) => usd(g.monto) },
          { k: 'x', t: '', f: (g) => <button onClick={() => borrar(g)} aria-label="Eliminar gasto">🗑️</button> },
        ]} />
      </Seccion>
    </>
  )
}
