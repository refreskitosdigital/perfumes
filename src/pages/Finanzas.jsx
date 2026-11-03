import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Tabla, Tarjeta, Aviso, Guia } from '../ui.jsx'
import { usd, bs, num, pct } from '../lib.js'
import Caja from './Caja.jsx'
import Tasas from './Tasas.jsx'
import PagosSocios from './PagosSocios.jsx'

// Finanzas: caja y compra de divisa, tasas con su brecha y la merma por pedido, todo junto.
const SUBS = [['caja', '🏦 Caja y compra de divisa'], ['tasas', '💱 Tasas y brecha'], ['merma', '📉 Merma por pedido'], ['socios', '🤝 Pagos a socios']]

export default function Finanzas() {
  const [sub, setSub] = useState(() => { const s = window.__finSub || 'caja'; window.__finSub = null; return s })
  return (
    <>
      <div className="subtabs" role="tablist" aria-label="Finanzas" style={{ marginBottom: 14 }}>
        {SUBS.map(([id, t]) => <button key={id} className={sub === id ? 'on' : ''} onClick={() => setSub(id)}>{t}</button>)}
      </div>
      {sub === 'caja' && <Caja />}
      {sub === 'tasas' && <><Tasas /><Brecha /></>}
      {sub === 'merma' && <Merma />}
      {sub === 'socios' && <PagosSocios />}
    </>
  )
}

// % que cuesta ir del BCV a Binance: lo que se pierde por cada dólar cobrado en Bs a tasa BCV
const brecha = (bcv, binance) => (num(bcv) > 0 && num(binance) > 0 ? num(binance) / num(bcv) - 1 : null)

function Brecha() {
  const { tasas } = useApp()
  const filas = tasas.data.slice(0, 30)
  const hoy = filas[0]
  return (
    <Seccion titulo="Brecha cambiaria" ayuda="Cuánto más caro es el dólar de Binance que el oficial. Es lo que se pierde al cobrar en Bs a tasa BCV y comprar divisa.">
      {hoy && (
        <div className="tarjetas">
          <Tarjeta titulo="BCV $ → Binance" valor={brecha(hoy.bcv, hoy.binance) == null ? '—' : pct(brecha(hoy.bcv, hoy.binance))} nota={hoy.bcv ? `${hoy.bcv} contra ${hoy.binance} Bs` : 'Falta la BCV $ de hoy'} tono={brecha(hoy.bcv, hoy.binance) > 0 ? 'malo' : ''} />
          <Tarjeta titulo="BCV Euro → Binance" valor={brecha(hoy.euro, hoy.binance) == null ? '—' : pct(brecha(hoy.euro, hoy.binance))} nota={hoy.euro ? `${hoy.euro} contra ${hoy.binance} Bs` : 'Falta la BCV Euro de hoy'} />
          <Tarjeta titulo="Por cada $100 cobrados en Bs a BCV $" valor={brecha(hoy.bcv, hoy.binance) == null ? '—' : usd(100 * (1 - num(hoy.bcv) / num(hoy.binance)))} nota="Es lo que se pierde al comprar divisa (merma)" />
        </div>
      )}
      <Tabla filas={filas} vacio="Aún no has cargado tasas." cols={[
        { k: 'fecha', t: 'Fecha', f: (r) => String(r.fecha).slice(0, 10) },
        { k: 'bcv', t: 'BCV $', num: true, f: (r) => r.bcv || '—' },
        { k: 'euro', t: 'BCV Euro', num: true, f: (r) => r.euro || '—' },
        { k: 'binance', t: 'Binance', num: true },
        { k: 'b1', t: 'Brecha BCV $', num: true, f: (r) => (brecha(r.bcv, r.binance) == null ? '—' : pct(brecha(r.bcv, r.binance))) },
        { k: 'b2', t: 'Brecha Euro', num: true, f: (r) => (brecha(r.euro, r.binance) == null ? '—' : pct(brecha(r.euro, r.binance))) },
      ]} />
    </Seccion>
  )
}

function Merma() {
  const ped = useQuery(() => supabase.from('merma_pedido_v').select('*').order('pedido_codigo'), [])
  const det = useQuery(() => supabase.from('merma_cobros_v').select('*').order('fecha', { ascending: false }).order('cobro_id', { ascending: false }), [])
  const conv = useQuery(() => supabase.from('conversiones_v').select('merma_usd,bs,divisa'), [])
  const [pedido, setPedido] = useState('todos')
  const suma = (a, k) => a.reduce((t, r) => t + num(r[k]), 0)
  const estimada = suma(ped.data, 'merma_usd')
  const real = suma(conv.data, 'merma_usd')
  const bsTot = suma(ped.data, 'bs')
  const filas = det.data.filter((r) => pedido === 'todos' || (r.pedido_codigo || 'Sin pedido') === pedido)
  return (
    <>
      <Aviso error={ped.error || det.error} />
      <Seccion titulo="¿Cuánto hemos perdido por la brecha?" ayuda="Cada cobro en bolívares se anota con la tasa BCV a la que pagó el cliente. La merma es lo que valían esos Bs a esa tasa menos lo que valen en Binance el día del cobro.">
        <div className="tarjetas">
          <Tarjeta titulo="Merma total estimada" valor={usd(estimada)} tono={estimada > 0 ? 'malo' : ''} nota={bsTot ? `En ${bs(bsTot)} cobrados` : ''} />
          <Tarjeta titulo="Merma real al comprar divisa" valor={usd(real)} tono={real > 0 ? 'malo' : ''} nota={conv.data.length ? `${conv.data.length} compras de divisa registradas` : 'Aún no registras compras de divisa'} />
          <Tarjeta titulo="Diferencia (estimada − real)" valor={usd(estimada - real)} nota="La estimada usa Binance del día del cobro; la real, lo que de verdad pagaste" />
        </div>
        <Guia>La merma estimada es la que se resta de la ganancia de cada pedido en <b>Rentabilidad</b>. La real sale de <b>Caja → Convertir bolívares en divisa</b> y sirve para comprobar que la estimación fue buena.</Guia>
      </Seccion>
      <Seccion titulo="Merma por pedido">
        <Tabla filas={ped.data} vacio="Aún no hay cobros en bolívares." cols={[
          { k: 'pedido_codigo', t: 'Pedido' },
          { k: 'cobros_bs', t: 'Cobros en Bs', num: true },
          { k: 'bs', t: 'Bs cobrados', num: true, f: (r) => bs(r.bs) },
          { k: 'nominal_usd', t: 'Valían a BCV', num: true, f: (r) => usd(r.nominal_usd) },
          { k: 'real_usd', t: 'Valen en Binance', num: true, f: (r) => usd(r.real_usd) },
          { k: 'merma_usd', t: 'Merma', num: true, f: (r) => <b className={num(r.merma_usd) > 0 ? 'alerta' : ''}>{usd(r.merma_usd)}</b> },
          { k: 'pct', t: '% perdido', num: true, f: (r) => (num(r.nominal_usd) > 0 ? pct(num(r.merma_usd) / num(r.nominal_usd)) : '—') },
        ]} />
      </Seccion>
      <Seccion titulo="Detalle por cobro" acciones={
        <select value={pedido} onChange={(e) => setPedido(e.target.value)} aria-label="Pedido">
          <option value="todos">Todos los pedidos</option>
          {ped.data.map((p) => <option key={p.pedido_codigo}>{p.pedido_codigo}</option>)}
        </select>}>
        <Tabla filas={filas} vacio="Sin cobros en bolívares." cols={[
          { k: 'fecha', t: 'Fecha', f: (r) => String(r.fecha).slice(0, 10) },
          { k: 'cliente', t: 'Cliente' },
          { k: 'pedido_codigo', t: 'Pedido', f: (r) => r.pedido_codigo || '—' },
          { k: 'bs', t: 'Bs', num: true, f: (r) => bs(r.bs) },
          { k: 'tasa_bcv', t: 'BCV pagada', num: true },
          { k: 'binance_dia', t: 'Binance del día', num: true },
          { k: 'nominal_usd', t: 'A BCV', num: true, f: (r) => usd(r.nominal_usd) },
          { k: 'merma_usd', t: 'Merma', num: true, f: (r) => <b className={num(r.merma_usd) > 0 ? 'alerta' : ''}>{usd(r.merma_usd)}</b> },
        ]} />
      </Seccion>
    </>
  )
}
