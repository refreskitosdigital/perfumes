import React from 'react'
import { useApp } from '../App.jsx'
import { precioSugerido, num, usd } from '../lib.js'

// Editor de líneas de un pedido: perfume, unidades, costo y precio de venta (con sugerido)
export default function LineasEditor({ lineas, setLineas, envio }) {
  const { perfumes, config } = useApp()
  const totalUnid = lineas.reduce((a, l) => a + num(l.unidades), 0)
  const envioU = totalUnid > 0 ? num(envio) / totalUnid : 0
  const cambiar = (i, campo, v) => setLineas(lineas.map((l, j) => (j === i ? { ...l, [campo]: v } : l)))
  const nueva = () => setLineas([...lineas, { nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
  const quitar = (i) => setLineas(lineas.filter((_, j) => j !== i))

  return (
    <div className="lineas">
      <datalist id="lista-perfumes">{perfumes.data.map((p) => <option key={p.id} value={p.nombre} />)}</datalist>
      <div className="linea cab"><span>Perfume</span><span>Unid.</span><span>Costo $</span><span>Costo real</span><span>Sugerido</span><span>Precio venta $</span><span /></div>
      {lineas.map((l, i) => {
        const real = num(l.costo_unitario) + envioU
        const sug = precioSugerido(real, num(config.ganancia_objetivo), config.base_ganancia, num(config.redondeo))
        return (
          <div className="linea" key={i}>
            <input list="lista-perfumes" value={l.nombre} onChange={(e) => cambiar(i, 'nombre', e.target.value)} placeholder="Nombre del perfume" />
            <input type="number" min="1" value={l.unidades} onChange={(e) => cambiar(i, 'unidades', e.target.value)} />
            <input type="number" step="0.01" min="0" value={l.costo_unitario} onChange={(e) => cambiar(i, 'costo_unitario', e.target.value)} />
            <span className="calc">{real ? usd(real) : '—'}</span>
            <button type="button" className="calc sug" disabled={!sug} onClick={() => cambiar(i, 'precio_detal', sug)} title="Usar el sugerido">{sug ? usd(sug) : '—'}</button>
            <input type="number" step="0.5" min="0" value={l.precio_detal ?? ''} onChange={(e) => cambiar(i, 'precio_detal', e.target.value)} />
            <button type="button" className="x" onClick={() => quitar(i)} aria-label="Quitar">×</button>
          </div>
        )
      })}
      <button type="button" onClick={nueva}>+ Agregar perfume</button>
    </div>
  )
}

export const lineasParaRpc = (lineas) =>
  lineas
    .filter((l) => l.nombre.trim())
    .map((l) => ({
      nombre: l.nombre.trim(),
      unidades: Number(l.unidades),
      costo_unitario: Number(l.costo_unitario),
      precio_detal: l.precio_detal === '' || l.precio_detal == null ? null : Number(l.precio_detal),
    }))

// Socios que participan en un pedido y cuánto aporta cada uno
// sel: { Juan: { on: true, aporte: '' }, ... }  · aporte vacío = partes iguales de la inversión
export function SociosEditor({ sel, setSel, inversion }) {
  const { socios } = useApp()
  const activos = socios.filter((n) => sel[n]?.on)
  const parte = activos.length ? inversion / activos.length : 0
  const cambiar = (n, patch) => setSel({ ...sel, [n]: { on: false, aporte: '', ...sel[n], ...patch } })
  return (
    <div className="socios-ed">
      <div className="ayuda">Socios de este pedido. La ganancia de este pedido se reparte solo entre ellos, en proporción a lo aportado.</div>
      {socios.map((n) => (
        <label key={n} className="socio-fila">
          <input type="checkbox" checked={Boolean(sel[n]?.on)} onChange={(e) => cambiar(n, { on: e.target.checked })} />
          <span>{n}</span>
          <input type="number" step="0.01" min="0" disabled={!sel[n]?.on} value={sel[n]?.aporte ?? ''}
                 placeholder={sel[n]?.on ? parte.toFixed(2) : ''} onChange={(e) => cambiar(n, { aporte: e.target.value })} />
        </label>
      ))}
    </div>
  )
}

export const sociosParaRpc = (sel, socios, inversion) => {
  const activos = socios.filter((n) => sel[n]?.on)
  const parte = activos.length ? inversion / activos.length : 0
  return activos.map((n) => ({ socio: n, aporte: sel[n].aporte === '' || sel[n].aporte == null ? parte : Number(sel[n].aporte) }))
}
export const sociosIniciales = (nombres, activos = ['Juan', 'George']) =>
  Object.fromEntries(nombres.map((n) => [n, { on: activos.includes(n), aporte: '' }]))
