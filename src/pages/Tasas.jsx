import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Aviso, Guia } from '../ui.jsx'
import { hoy, tasaVenta } from '../lib.js'

export default function Tasas() {
  const { tasas, tasa, recargarTasas } = useApp()
  const [f, setF] = useState({ fecha: hoy(), euro: tasa?.euro ?? '', binance: tasa?.binance ?? '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const guardar = async (e) => {
    e.preventDefault()
    const { error } = await supabase.from('tasas').upsert({ fecha: f.fecha, euro: Number(f.euro), binance: Number(f.binance) })
    if (error) return setMsg({ error: /euro/.test(error.message) ? 'Falta ejecutar migracion_v6.sql en Supabase.' : error.message, ok: '' })
    setMsg({ error: '', ok: 'Tasa guardada. La tienda online ya muestra la nueva tasa BCV Euro.' })
    recargarTasas()
  }
  return (
    <Seccion titulo="Tasa del día" ayuda="La tasa BCV Euro es la única que ven los clientes y la que usan las ventas. La Binance es solo interna.">
      <Guia>Escribe aquí la <b>tasa BCV Euro</b> cada día: se actualiza sola en la tienda online (ahí se calcula cuánto pagan en bolívares). La <b>Binance</b> es solo para uso interno: se usa para valorar la caja y comprar divisas para recomprar mercancía, y <b>nunca se muestra en la tienda</b>.</Guia>
      <form className="form" onSubmit={guardar}>
        <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
        <Campo label="BCV Euro (Bs por €) · tienda y ventas"><input type="number" step="0.01" min="0" value={f.euro} onChange={(e) => setF({ ...f, euro: e.target.value })} required /></Campo>
        <Campo label="Binance (Bs por $) · solo interna"><input type="number" step="0.01" min="0" value={f.binance} onChange={(e) => setF({ ...f, binance: e.target.value })} required /></Campo>
        <button className="primario" type="submit">Guardar tasa</button>
      </form>
      <Aviso {...msg} />
      <Tabla filas={tasas.data} cols={[
        { k: 'fecha', t: 'Fecha' },
        { k: 'v', t: 'BCV Euro (venta)', num: true, f: (r) => tasaVenta(r).toLocaleString('es-VE') + (r.euro ? '' : ' (dólar BCV, antigua)') },
        { k: 'binance', t: 'Binance (interna)', num: true },
      ]} />
    </Seccion>
  )
}
