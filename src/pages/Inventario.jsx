import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Tabla, Aviso } from '../ui.jsx'
import { usd, pct, precioSugerido, num } from '../lib.js'

export default function Inventario() {
  const { config, recargarPerfumes } = useApp()
  const inv = useQuery(() => supabase.from('inventario_v').select('*').order('sku'), [])
  const [error, setError] = useState('')

  const editar = async (id, campo, valor) => {
    const v = valor === '' ? null : Number(valor)
    const { error } = await supabase.from('perfumes').update({ [campo]: v }).eq('id', id)
    setError(error ? error.message : '')
    inv.recargar(); recargarPerfumes()
  }
  const celda = (campo) => (r) => (
    <input className="mini" type="number" step="0.5" defaultValue={r[campo] ?? ''} onBlur={(e) => {
      if (String(r[campo] ?? '') !== e.target.value) editar(r.id, campo, e.target.value)
    }} />
  )

  return (
    <Seccion titulo="Inventario" ayuda={`Los perfumes y SKU se crean solos al registrar compras. Edita los precios aquí. El precio al mayor aplica desde ${config.umbral_mayor} unidades.`}>
      <Aviso error={error || inv.error} />
      <Tabla filas={inv.data} cols={[
        { k: 'sku', t: 'SKU' }, { k: 'nombre', t: 'Perfume' },
        { k: 'stock', t: 'Stock', num: true, f: (r) => <b className={r.stock <= 1 ? 'alerta' : ''}>{r.stock < 0 ? `${r.stock} (por comprar)` : r.stock}</b> },
        { k: 'comprados', t: 'Comprados', num: true }, { k: 'vendidos', t: 'Vendidos', num: true },
        { k: 'costo', t: 'Costo real', num: true, f: (r) => usd(r.costo) },
        { k: 'sug', t: `Sugerido ${pct(config.ganancia_objetivo)}`, num: true, f: (r) => usd(precioSugerido(r.costo, num(config.ganancia_objetivo), config.base_ganancia, num(config.redondeo))) },
        { k: 'precio_detal', t: 'Detal $', num: true, f: celda('precio_detal') },
        { k: 'precio_mayor', t: 'Mayor $', num: true, f: celda('precio_mayor') },
        { k: 'margen_detal', t: 'Rent. detal', num: true, f: (r) => pct(r.margen_detal) },
        { k: 'margen_mayor', t: 'Rent. mayor', num: true, f: (r) => pct(r.margen_mayor) },
        { k: 'ganancia', t: 'Ganancia', num: true, f: (r) => usd(r.ganancia) },
      ]} />
    </Seccion>
  )
}
