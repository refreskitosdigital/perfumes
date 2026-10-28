import React, { useMemo } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion } from '../ui.jsx'
import { hoy, usd, num, normNombre, cobroDelDia } from '../lib.js'

const digitos = (t) => String(t || '').replace(/\D/g, '')
const tel58 = (t) => { const d = digitos(t); return d.startsWith('0') ? '58' + d.slice(1) : d }
const wa = (numero, texto) => `https://wa.me/${numero || ''}?text=${encodeURIComponent(texto)}`
const corta = (f) => (f ? String(f).slice(8, 10) + '/' + String(f).slice(5, 7) : '')

// Lo que toca cobrar hoy o ya está vencido: clientes con saldo y fecha de pago, y pedidos de vendedoras cuyo cliente debía pagar.
// Se usa en Inicio y en Por cobrar. Si no hay nada, no muestra nada.
export function useCobrosHoy() {
  const ventas = useQuery(() => supabase.from('ventas_v').select('id,cliente,nombre,unidades,pendiente_usd,vence,vendedor').gt('pendiente_usd', 0.005).lte('vence', hoy()).order('vence'), [])
  const clientes = useQuery(() => supabase.from('clientes').select('nombre,telefono'), [])
  const vend = useQuery(() => supabase.from('vendedora_pedidos_v').select('id,vendedora,cliente,telefono,plan,fecha1,fecha2,creado,estado,total_venta,cobrado_cliente').in('estado', ['aprobado', 'entregado']), [])
  const telDe = useMemo(() => Object.fromEntries(clientes.data.filter((c) => c.telefono).map((c) => [normNombre(c.nombre), c.telefono])), [clientes.data])

  const clientesDeben = useMemo(() => ventas.data.map((v) => ({ ...v, telefono: telDe[normNombre(v.cliente.replace(/\s*\(vía.*\)$/, ''))] || '' })), [ventas.data, telDe])
  const vendedoras = useMemo(() => vend.data
    .map((p) => ({ p, c: cobroDelDia({ plan: p.plan, fecha1: p.fecha1, fecha2: p.fecha2, creado: p.creado, total: p.total_venta, cobrado: p.cobrado_cliente }) }))
    .filter((x) => x.c), [vend.data])
  const total = clientesDeben.reduce((a, v) => a + num(v.pendiente_usd), 0)
  return { clientesDeben, vendedoras, total, cantidad: clientesDeben.length + vendedoras.length, error: ventas.error || vend.error }
}

export default function CobrosHoy({ datos, titulo = '🔔 Cobros de hoy' }) {
  const propio = useCobrosHoy()
  const { clientesDeben, vendedoras, cantidad } = datos || propio
  if (!cantidad) return null
  return (
    <Seccion titulo={titulo} ayuda="Clientes cuya fecha de pago es hoy o ya pasó y todavía deben. Pulsa el botón para escribirles por WhatsApp con el mensaje listo.">
      <div className="cobros-hoy">
        {clientesDeben.map((v) => (
          <div className="cobro-fila" key={v.id}>
            <span><b>{v.cliente}</b><small>{v.nombre}{v.unidades > 1 ? ` ×${v.unidades}` : ''} · {v.vence === hoy() ? 'vence hoy' : 'venció el ' + corta(v.vence)}</small></span>
            <b>{usd(v.pendiente_usd)}</b>
            <a className="boton" href={wa(tel58(v.telefono), `Hola ${v.cliente.split(' ')[0]}, te escribo de MOTOSA PARFUM. Hoy toca el pago de ${usd(v.pendiente_usd)} por tu pedido de perfumes (${v.nombre}). ¿Me confirmas cuándo me lo puedes enviar? ¡Gracias!`)} target="_blank" rel="noopener noreferrer">Recordar por WhatsApp</a>
          </div>
        ))}
        {vendedoras.map(({ p, c }) => (
          <div className="cobro-fila" key={'v' + p.id}>
            <span><b>{p.vendedora} debe cobrar a {p.cliente}</b><small>pedido #{p.id} · {c.desde === hoy() ? 'toca hoy' : 'desde el ' + corta(c.desde)}</small></span>
            <b>{usd(c.monto)}</b>
            <a className="boton" href={wa('', `Hola ${p.vendedora}, hoy le toca pagar ${usd(c.monto)} a ${p.cliente} (pedido #${p.id}). ¿Ya le cobraste? Cuando lo tengas, anótalo en tu app. ¡Gracias!`)} target="_blank" rel="noopener noreferrer">Avisar a la vendedora</a>
          </div>
        ))}
      </div>
    </Seccion>
  )
}
