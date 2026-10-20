import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Aviso } from '../ui.jsx'
import { hoy, descuentoMax, factor, pct } from '../lib.js'

export default function Tasas() {
  const { tasas, tasa, recargarTasas } = useApp()
  const [f, setF] = useState({ fecha: hoy(), bcv: tasa?.bcv ?? '', binance: tasa?.binance ?? '' })
  const [error, setError] = useState('')
  const guardar = async (e) => {
    e.preventDefault()
    const { error } = await supabase.from('tasas').upsert({ fecha: f.fecha, bcv: Number(f.bcv), binance: Number(f.binance) })
    setError(error ? error.message : '')
    if (!error) recargarTasas()
  }
  return (
    <Seccion titulo="Tasas del día" ayuda="Registra BCV y Binance cada día. Las ventas guardan la tasa con la que se hicieron.">
      <form className="form" onSubmit={guardar}>
        <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
        <Campo label="BCV (Bs por $)"><input type="number" step="0.01" value={f.bcv} onChange={(e) => setF({ ...f, bcv: e.target.value })} required /></Campo>
        <Campo label="Binance (Bs por $)"><input type="number" step="0.01" value={f.binance} onChange={(e) => setF({ ...f, binance: e.target.value })} required /></Campo>
        <button className="primario" type="submit">Guardar tasa</button>
      </form>
      <Aviso error={error} />
      <Tabla filas={tasas.data} cols={[
        { k: 'fecha', t: 'Fecha' },
        { k: 'bcv', t: 'BCV', num: true }, { k: 'binance', t: 'Binance', num: true },
        { k: 'f', t: 'Factor', num: true, f: (r) => factor(r.bcv, r.binance).toFixed(4) },
        { k: 'd', t: 'Descuento máx. divisa', num: true, f: (r) => pct(descuentoMax(r.bcv, r.binance)) },
      ]} />
    </Seccion>
  )
}
