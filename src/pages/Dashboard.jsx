import React from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Tarjeta, Seccion, Tabla, Aviso } from '../ui.jsx'
import { usd, bs, num, pct } from '../lib.js'

export default function Dashboard() {
  const res = useQuery(() => supabase.from('ganancia_pedido_v').select('*').order('codigo'), [])
  const soc = useQuery(() => supabase.from('ganancia_socios_v').select('*').order('socio'), [])
  const ven = useQuery(() => supabase.from('ventas_v').select('valor_usd,cobrado_usd,pendiente_usd'), [])
  const inv = useQuery(() => supabase.from('inventario_v').select('*'), [])
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const pre = useQuery(() => supabase.from('prestamos').select('*'), [])

  const suma = (arr, k) => arr.reduce((a, r) => a + num(r[k]), 0)
  const inversion = suma(res.data, 'inversion')
  const vendido = suma(ven.data, 'valor_usd')
  const cobrado = suma(ven.data, 'cobrado_usd')
  const pendiente = suma(ven.data, 'pendiente_usd')
  const ganancia = suma(res.data, 'ganancia')
  const deuda = pre.data.reduce((a, r) => a + num(r.monto) - num(r.devuelto), 0)
  const stockCosto = inv.data.reduce((a, r) => a + Math.max(num(r.stock), 0) * num(r.costo), 0)
  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)
  const top = [...inv.data].filter((r) => r.vendidos > 0).sort((a, b) => b.vendidos - a.vendidos).slice(0, 5)
  const pocos = inv.data.filter((r) => r.stock < 0 || (r.comprados > 0 && r.stock === 1)).sort((a, b) => a.stock - b.stock)
  const error = res.error || ven.error || soc.error || inv.error || caja.error || pre.error

  return (
    <>
      <Aviso error={error} />
      <Seccion titulo="Resumen del negocio" ayuda="Se calcula solo a partir de Compras, Ventas y Cobros. Los Bs se valoran a Binance.">
        <div className="tarjetas">
          <Tarjeta titulo="Inversión total" valor={usd(inversion)} />
          <Tarjeta titulo="Vendido (valor real)" valor={usd(vendido)} />
          <Tarjeta titulo="Ya cobrado" valor={usd(cobrado)} />
          <Tarjeta titulo="Por cobrar" valor={usd(pendiente)} tono={pendiente > 0 ? 'malo' : ''} />
          <Tarjeta titulo="Ganancia (vendido − costo)" valor={usd(ganancia)} tono={ganancia >= 0 ? 'bueno' : 'malo'} nota={inversion ? `Sobre inversión ${pct(ganancia / inversion)}` : ''} />
          <Tarjeta titulo="Préstamo por devolver" valor={usd(deuda)} tono={deuda > 0 ? 'malo' : ''} />
          <Tarjeta titulo="Mercancía en stock (a costo)" valor={usd(stockCosto)} />
        </div>
      </Seccion>

      <Seccion titulo="Dinero disponible" ayuda="Cobros recibidos más los movimientos manuales de Caja.">
        <div className="tarjetas">
          <Tarjeta titulo="Binance" valor={usd(saldo('binance'))} />
          <Tarjeta titulo="Efectivo" valor={usd(saldo('efectivo'))} />
          <Tarjeta titulo="Bolívares" valor={bs(saldo('bs'))} />
        </div>
      </Seccion>

      <div className="dos-col">
        <Seccion titulo="Resultado por pedido">
          <Tabla filas={res.data} cols={[
            { k: 'codigo', t: 'Pedido' },
            { k: 'inversion', t: 'Inversión', num: true, f: (r) => usd(r.inversion) },
            { k: 'ventas_usd', t: 'Vendido', num: true, f: (r) => usd(r.ventas_usd) },
            { k: 'cobrado_usd', t: 'Cobrado', num: true, f: (r) => usd(r.cobrado_usd) },
            { k: 'ganancia', t: 'Ganancia', num: true, f: (r) => <b>{usd(r.ganancia)}</b> },
          ]} />
        </Seccion>
        <Seccion titulo="Por socio" ayuda="Cada pedido reparte su ganancia solo entre sus socios.">
          <Tabla filas={soc.data} cols={[
            { k: 'socio', t: 'Socio' },
            { k: 'aportes', t: 'Aportado', num: true, f: (r) => usd(r.aportes) },
            { k: 'ganancia', t: 'Ganancia', num: true, f: (r) => <b>{usd(r.ganancia)}</b> },
          ]} />
        </Seccion>
      </div>

      <div className="dos-col">
        <Seccion titulo="Top 5 más vendidos">
          <Tabla vacio="Aún no hay ventas." filas={top} cols={[
            { k: 'sku', t: 'SKU' }, { k: 'nombre', t: 'Perfume' },
            { k: 'vendidos', t: 'Vendidos', num: true }, { k: 'stock', t: 'Stock', num: true },
          ]} />
        </Seccion>
        <Seccion titulo="Por comprar y últimas unidades" ayuda="Negativo = vendido sin comprar todavía. Positivo = queda 1.">
          <Tabla vacio="Nada urgente." filas={pocos} cols={[
            { k: 'sku', t: 'SKU' }, { k: 'nombre', t: 'Perfume' }, { k: 'stock', t: 'Stock', num: true },
          ]} />
        </Seccion>
      </div>
    </>
  )
}
