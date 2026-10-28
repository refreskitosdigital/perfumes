import React, { useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Tarjeta, Aviso } from '../ui.jsx'
import { usd, num, normNombre } from '../lib.js'
import { descargarExcel } from '../excel.js'

// Qué comprar en el próximo pedido al proveedor, perfume por perfume:
//   A comprar = (pedidos de la tienda por atender + clientes que agendaron) - existencia - lo que ya está en una agenda de compra
// La existencia puede ser negativa: son ventas ya hechas (por ejemplo, pedidos de vendedoras aprobados) de perfumes que no se tenían.
export default function ListaCompra() {
  const inv = useQuery(() => supabase.from('inventario_v').select('id,nombre,stock,costo,comprados'), [])
  const web = useQuery(() => supabase.from('pedidos_web_items').select('perfume_id, unidades, pedidos_web!inner(estado)').eq('pedidos_web.estado', 'nuevo'), [])
  const dem = useQuery(() => supabase.from('demanda_web').select('perfume_id, unidades').eq('atendido', false), [])
  const vendSin = useQuery(() => supabase.from('ventas').select('perfume_id, unidades, cliente').is('pedido_codigo', null).like('cliente', '%(vía %'), [])
  const agenda = useQuery(() => supabase.from('agenda_lineas').select('nombre, unidades, costo_unitario, agenda_pedidos!inner(codigo, registrado)').eq('agenda_pedidos.registrado', false), [])
  const [copiado, setCopiado] = useState(false)

  const filas = useMemo(() => {
    const suma = (arr, k = 'unidades') => { const m = {}; arr.forEach((r) => { m[r.perfume_id] = (m[r.perfume_id] || 0) + num(r[k]) }); return m }
    const w = suma(web.data), a = suma(dem.data), vs = suma(vendSin.data)
    const ag = {}; agenda.data.forEach((l) => { const k = normNombre(l.nombre); ag[k] = (ag[k] || 0) + num(l.unidades) })
    return inv.data.map((p) => {
      const stock = num(p.stock), enAgenda = ag[normNombre(p.nombre)] || 0
      const pedidosTienda = w[p.id] || 0, agendados = a[p.id] || 0
      const necesario = Math.max(0, pedidosTienda + agendados - stock)
      const comprar = Math.max(0, necesario - enAgenda)
      return { id: p.id, nombre: p.nombre, stock, vendedoras: vs[p.id] || 0, pedidosTienda, agendados, enAgenda, comprar, costo: num(p.costo) }
    }).filter((r) => r.comprar > 0 || r.enAgenda > 0 || r.stock < 0 || r.pedidosTienda > 0 || r.agendados > 0)
      .sort((x, y) => y.comprar - x.comprar || x.nombre.localeCompare(y.nombre, 'es'))
  }, [inv.data, web.data, dem.data, vendSin.data, agenda.data])

  const aComprar = filas.filter((r) => r.comprar > 0)
  const unidades = aComprar.reduce((a, r) => a + r.comprar, 0)
  const estimado = aComprar.reduce((a, r) => a + r.comprar * r.costo, 0)
  const error = inv.error || web.error || dem.error || vendSin.error || agenda.error

  const texto = () => 'Lista de compra\n' + aComprar.map((r) => `• ${r.comprar} × ${r.nombre}`).join('\n') + `\n\nTotal: ${unidades} perfumes`
  const copiar = async () => { try { await navigator.clipboard.writeText(texto()); setCopiado(true); setTimeout(() => setCopiado(false), 2500) } catch { window.prompt('Copia la lista:', texto()) } }
  const excel = () => descargarExcel('lista-de-compra', { 'Lista de compra': aComprar.map((r) => ({ Perfume: r.nombre, 'A comprar': r.comprar, 'Existencia': r.stock, 'Pedidos tienda': r.pedidosTienda, 'Agendados': r.agendados, 'Ya en agenda de compra': r.enAgenda, 'Costo aprox. c/u': r.costo ? Math.round(r.costo * 100) / 100 : '' })) })

  return (
    <Seccion titulo="Lista de compra" ayuda="Suma lo que hay que conseguir para el próximo pedido al proveedor: ventas hechas sin stock (incluye pedidos aprobados de vendedoras), pedidos de la tienda sin atender y clientes que agendaron. Descuenta lo que ya tienes y lo que ya está en una agenda de compra."
      acciones={aComprar.length > 0 && <div className="acciones-fila"><button onClick={copiar}>{copiado ? '✓ Copiada' : 'Copiar lista'}</button><button onClick={excel}>Descargar Excel</button></div>}>
      <Aviso error={error} />
      <div className="tarjetas">
        <Tarjeta titulo="Perfumes a comprar" valor={String(unidades)} nota={`${aComprar.length} modelos`} />
        <Tarjeta titulo="Inversión aproximada" valor={usd(estimado)} nota="Con el costo promedio de cada perfume" />
      </div>
      {!filas.length && <p className="vacio">Nada por comprar por ahora. 🎉</p>}
      {filas.length > 0 && (
        <div className="tabla-wrap"><table>
          <thead><tr><th>Perfume</th><th className="num">Existencia</th><th className="num" title="Ventas hechas sin tener el perfume, de pedidos de vendedoras">Vendedoras sin stock</th><th className="num">Pedidos tienda</th><th className="num">Agendados</th><th className="num">Ya en agenda</th><th className="num">A comprar</th></tr></thead>
          <tbody>
            {filas.map((r) => (
              <tr key={r.id} className={r.comprar > 0 ? '' : 'tenue'}>
                <td>{r.nombre}</td>
                <td className={'num' + (r.stock < 0 ? ' vencido' : '')}>{r.stock}</td>
                <td className="num">{r.vendedoras || ''}</td><td className="num">{r.pedidosTienda || ''}</td><td className="num">{r.agendados || ''}</td><td className="num">{r.enAgenda || ''}</td>
                <td className="num"><b>{r.comprar || '—'}</b></td>
              </tr>
            ))}
          </tbody>
        </table></div>
      )}
      <p className="ayuda">Existencia en negativo = ya está vendido y no lo tienes. «Vendedoras sin stock» es informativo: ya está contado en la existencia negativa.</p>
    </Seccion>
  )
}
