import React, { useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Tarjeta, Seccion, Tabla, Aviso, Guia } from '../ui.jsx'
import { usd, num, pct, cajaUsd } from '../lib.js'
import { CATEGORIAS } from './Gastos.jsx'

// Lunes de la semana de una fecha 'YYYY-MM-DD' (sin problemas de zona horaria)
const lunes = (s) => {
  const [y, m, d] = String(s).slice(0, 10).split('-').map(Number)
  const dt = new Date(Date.UTC(y, m - 1, d))
  const dow = (dt.getUTCDay() + 6) % 7
  dt.setUTCDate(dt.getUTCDate() - dow)
  return dt.toISOString().slice(0, 10)
}
const MESES = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic']
const etiqueta = (clave, modo) => {
  if (modo === 'mes') { const [y, m] = clave.split('-'); return `${MESES[Number(m) - 1]} ${y}` }
  const [y, m, d] = clave.split('-').map(Number)
  const fin = new Date(Date.UTC(y, m - 1, d + 6))
  return `${d} ${MESES[m - 1]} – ${fin.getUTCDate()} ${MESES[fin.getUTCMonth()]}`
}
const clavePeriodo = (fecha, modo) => (modo === 'mes' ? String(fecha).slice(0, 7) : lunes(fecha))

export default function Rentabilidad() {
  const { tasa } = useApp()
  const ped = useQuery(() => supabase.from('rentabilidad_pedido_v').select('*').order('codigo'), [])
  const soc = useQuery(() => supabase.from('rentabilidad_socios_v').select('*').order('socio'), [])
  const ven = useQuery(() => supabase.from('ventas_v').select('fecha,valor_usd,cobrado_usd,pendiente_usd,costo_total,ganancia'), [])
  const gas = useQuery(() => supabase.from('gastos').select('fecha,categoria,monto,pedido_codigo'), [])
  const inv = useQuery(() => supabase.from('inventario_v').select('stock,costo'), [])
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const pre = useQuery(() => supabase.from('prestamos').select('monto,devuelto'), [])
  const [modo, setModo] = useState('semana')

  const suma = (arr, k) => arr.reduce((a, r) => a + num(r[k]), 0)
  const inversion = suma(ped.data, 'inversion')
  const vendido = suma(ven.data, 'valor_usd')
  const cobrado = suma(ven.data, 'cobrado_usd')
  const porCobrar = suma(ven.data, 'pendiente_usd')
  const bruta = suma(ped.data, 'ganancia_bruta')
  const gastosTot = suma(gas.data, 'monto')
  const neta = bruta - gastosTot
  const stockCosto = inv.data.reduce((a, r) => a + Math.max(num(r.stock), 0) * num(r.costo), 0)
  const enCaja = cajaUsd(caja.data, tasa?.binance)
  const deuda = pre.data.reduce((a, r) => a + num(r.monto) - num(r.devuelto), 0)
  const margen = vendido > 0 ? bruta / vendido : null
  const error = ped.error || soc.error || ven.error || gas.error || inv.error || caja.error || pre.error

  // Gastos generales (sin pedido): se reparten a partes iguales entre los socios
  const generales = gas.data.filter((g) => !g.pedido_codigo).reduce((a, g) => a + num(g.monto), 0)
  const nSocios = Math.max(soc.data.length, 1)

  // Ventas, costo y ganancia por semana o mes
  const periodos = useMemo(() => {
    const m = new Map()
    const f = (k) => { if (!m.has(k)) m.set(k, { k, n: 0, vendido: 0, costo: 0, bruta: 0, gastos: 0 }); return m.get(k) }
    ven.data.forEach((v) => {
      const p = f(clavePeriodo(v.fecha, modo))
      p.n += 1; p.vendido += num(v.valor_usd); p.costo += num(v.costo_total); p.bruta += num(v.ganancia)
    })
    gas.data.forEach((g) => { f(clavePeriodo(g.fecha, modo)).gastos += num(g.monto) })
    return [...m.values()].sort((a, b) => (a.k < b.k ? 1 : -1))
  }, [ven.data, gas.data, modo])
  const maxVend = Math.max(1, ...periodos.map((p) => p.vendido))
  const conVar = periodos.map((p, i) => {
    const ant = periodos[i + 1]
    return { ...p, neta: p.bruta - p.gastos, delta: ant && ant.vendido > 0 ? (p.vendido - ant.vendido) / ant.vendido : null }
  })

  const porCat = Object.keys(CATEGORIAS).map((k) => [k, gas.data.filter((g) => g.categoria === k).reduce((a, g) => a + num(g.monto), 0)]).filter(([, v]) => v > 0)

  return (
    <>
      <Aviso error={error} />
      <Seccion titulo="¿Cómo va el negocio?" ayuda="Todo sale de lo que registras en Ventas, Compras y Gastos. La ganancia es lo vendido menos lo que costó la mercancía (con su envío), y la neta además resta los gastos.">
        <div className="tarjetas grandes">
          <Tarjeta titulo="💰 Ganancia neta" valor={usd(neta)} tono={neta >= 0 ? 'bueno' : 'malo'} nota={inversion ? `${pct(neta / inversion)} sobre la inversión` : ''} />
          <Tarjeta titulo="📈 Ganancia bruta" valor={usd(bruta)} tono={bruta >= 0 ? 'bueno' : 'malo'} nota={inversion ? `${pct(bruta / inversion)} sobre la inversión${margen != null ? ' · margen ' + pct(margen) : ''}` : ''} />
          <Tarjeta titulo="📥 Nos deben" valor={usd(porCobrar)} tono={porCobrar > 0 ? 'malo' : ''} nota="Ventas por cobrar" />
          <Tarjeta titulo="💵 Dinero en caja" valor={usd(enCaja)} tono="bueno" nota="Binance + efectivo + Bs" />
        </div>
      </Seccion>

      <Seccion titulo="Resumen general">
        <div className="tarjetas">
          <Tarjeta titulo="Inversión total" valor={usd(inversion)} nota="Mercancía + envíos de todos los lotes" />
          <Tarjeta titulo="Vendido" valor={usd(vendido)} />
          <Tarjeta titulo="Cobrado" valor={usd(cobrado)} nota={vendido ? `${pct(cobrado / vendido)} de lo vendido` : ''} />
          <Tarjeta titulo="Por cobrar" valor={usd(porCobrar)} tono={porCobrar > 0 ? 'malo' : ''} />
          <Tarjeta titulo="Gastos" valor={usd(gastosTot)} tono={gastosTot > 0 ? 'malo' : ''} nota="Delivery, traslados, etc." />
          <Tarjeta titulo="Mercancía en stock (a costo)" valor={usd(stockCosto)} />
          <Tarjeta titulo="Préstamos por devolver" valor={usd(deuda)} tono={deuda > 0 ? 'malo' : ''} />
        </div>
      </Seccion>

      <Seccion titulo="Ventas por período" ayuda="Compara cada semana o mes con el anterior."
        acciones={
          <div className="subtabs" role="tablist" aria-label="Período">
            <button className={modo === 'semana' ? 'on' : ''} onClick={() => setModo('semana')}>Por semana</button>
            <button className={modo === 'mes' ? 'on' : ''} onClick={() => setModo('mes')}>Por mes</button>
          </div>
        }>
        {!conVar.length ? <p className="vacio">Aún no hay ventas registradas.</p> : (
          <>
            <div className="barras" role="img" aria-label="Vendido por período">
              {conVar.slice(0, 8).reverse().map((p) => (
                <div className="barra-fila" key={p.k}>
                  <span className="barra-et">{etiqueta(p.k, modo)}</span>
                  <div className="barra-pista"><div className="barra-rel" style={{ width: (p.vendido / maxVend) * 100 + '%' }} /></div>
                  <b>{usd(p.vendido)}</b>
                </div>
              ))}
            </div>
            <Tabla filas={conVar} cols={[
              { k: 'k', t: modo === 'mes' ? 'Mes' : 'Semana', f: (p) => etiqueta(p.k, modo) },
              { k: 'n', t: 'Ventas', num: true },
              { k: 'vendido', t: 'Vendido', num: true, f: (p) => usd(p.vendido) },
              { k: 'delta', t: 'vs. anterior', num: true, f: (p) => (p.delta == null ? '—' : <span className={p.delta >= 0 ? 'bueno' : 'alerta'}>{(p.delta >= 0 ? '+' : '') + pct(p.delta)}</span>) },
              { k: 'costo', t: 'Costo', num: true, f: (p) => usd(p.costo) },
              { k: 'bruta', t: 'Ganancia', num: true, f: (p) => usd(p.bruta) },
              { k: 'gastos', t: 'Gastos', num: true, f: (p) => usd(p.gastos) },
              { k: 'neta', t: 'Neta', num: true, f: (p) => <b className={p.neta >= 0 ? 'bueno' : 'alerta'}>{usd(p.neta)}</b> },
            ]} />
            <Guia>Las ventas sin costo conocido (por ejemplo, una reserva de un perfume que aún no compras) suman en "Vendido" pero su ganancia se cuenta cuando se registra la compra.</Guia>
          </>
        )}
      </Seccion>

      <Seccion titulo="Ganancia por pedido (lote)">
        <Tabla filas={ped.data} cols={[
          { k: 'codigo', t: 'Pedido' },
          { k: 'inversion', t: 'Inversión', num: true, f: (r) => usd(r.inversion) },
          { k: 'ventas_usd', t: 'Vendido', num: true, f: (r) => usd(r.ventas_usd) },
          { k: 'cobrado_usd', t: 'Cobrado', num: true, f: (r) => usd(r.cobrado_usd) },
          { k: 'pendiente_usd', t: 'Por cobrar', num: true, f: (r) => (num(r.pendiente_usd) > 0.01 ? <b className="alerta">{usd(r.pendiente_usd)}</b> : '') },
          { k: 'ganancia_bruta', t: 'Ganancia', num: true, f: (r) => usd(r.ganancia_bruta) },
          { k: 'gastos', t: 'Gastos', num: true, f: (r) => usd(r.gastos) },
          { k: 'ganancia_neta', t: 'Neta', num: true, f: (r) => <b className={num(r.ganancia_neta) >= 0 ? 'bueno' : 'alerta'}>{usd(r.ganancia_neta)}</b> },
          { k: 'roi', t: '% s/ inversión', num: true, f: (r) => (num(r.inversion) > 0 ? pct(num(r.ganancia_neta) / num(r.inversion)) : '—') },
        ]} />
      </Seccion>

      <Seccion titulo="Ganancia por socio" ayuda={generales > 0 ? `Incluye ${usd(generales)} de gastos generales repartidos a partes iguales (${usd(generales / nSocios)} cada uno).` : 'Cada pedido reparte su ganancia neta según la participación de sus socios.'}>
        <Tabla filas={soc.data} cols={[
          { k: 'socio', t: 'Socio' },
          { k: 'aportes', t: 'Aportó', num: true, f: (r) => usd(r.aportes) },
          { k: 'ganancia_bruta', t: 'Ganancia', num: true, f: (r) => usd(r.ganancia_bruta) },
          { k: 'gastos', t: 'Gastos', num: true, f: (r) => usd(num(r.gastos) + generales / nSocios) },
          { k: 'ganancia_neta', t: 'Neta', num: true, f: (r) => <b className="bueno">{usd(num(r.ganancia_neta) - generales / nSocios)}</b> },
          { k: 'roi', t: '% s/ aporte', num: true, f: (r) => (num(r.aportes) > 0 ? pct((num(r.ganancia_neta) - generales / nSocios) / num(r.aportes)) : '—') },
        ]} />
      </Seccion>

      {porCat.length > 0 && (
        <Seccion titulo="¿En qué se van los gastos?">
          <div className="tarjetas">{porCat.map(([k, v]) => <Tarjeta key={k} titulo={CATEGORIAS[k]} valor={usd(v)} nota={gastosTot ? pct(v / gastosTot) : ''} />)}</div>
        </Seccion>
      )}
    </>
  )
}
