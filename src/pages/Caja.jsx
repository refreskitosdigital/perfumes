import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Tabla, Tarjeta, Aviso } from '../ui.jsx'
import { hoy, usd, bs, num } from '../lib.js'

export default function Caja() {
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const mov = useQuery(() => supabase.from('movimientos').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }), [])
  const [f, setF] = useState({ fecha: hoy(), cuenta: 'binance', tipo: 'sale', monto: '', nota: '' })
  const [error, setError] = useState('')
  const pre = useQuery(() => supabase.from('prestamos').select('*').order('fecha', { ascending: false }), [])
  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)

  const guardar = async (e) => {
    e.preventDefault()
    const m = Math.abs(Number(f.monto)) * (f.tipo === 'sale' ? -1 : 1)
    const { error } = await supabase.from('movimientos').insert({ fecha: f.fecha, cuenta: f.cuenta, monto: m, nota: f.nota })
    setError(error ? error.message : '')
    if (!error) { setF({ ...f, monto: '', nota: '' }); caja.recargar(); mov.recargar() }
  }

  

  return (
    <>
      <Seccion titulo="Saldos" ayuda="Ventas cobradas por cuenta más los movimientos que registres aquí (pago a proveedor, retiros, conversiones).">
        <div className="tarjetas">
          <Tarjeta titulo="Binance" valor={usd(saldo('binance'))} />
          <Tarjeta titulo="Efectivo" valor={usd(saldo('efectivo'))} />
          <Tarjeta titulo="Bolívares" valor={bs(saldo('bs'))} />
        </div>
      </Seccion>
      <Seccion titulo="Registrar movimiento">
        <form className="form" onSubmit={guardar}>
          <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
          <Campo label="Cuenta">
            <select value={f.cuenta} onChange={(e) => setF({ ...f, cuenta: e.target.value })}>
              <option value="binance">Binance ($)</option><option value="efectivo">Efectivo ($)</option><option value="bs">Bolívares (Bs)</option>
            </select>
          </Campo>
          <Campo label="Tipo">
            <select value={f.tipo} onChange={(e) => setF({ ...f, tipo: e.target.value })}>
              <option value="sale">Sale (gasto, pago, retiro)</option><option value="entra">Entra (aporte, ajuste)</option>
            </select>
          </Campo>
          <Campo label="Monto"><input type="number" step="0.01" min="0" value={f.monto} onChange={(e) => setF({ ...f, monto: e.target.value })} required /></Campo>
          <Campo label="Nota"><input value={f.nota} onChange={(e) => setF({ ...f, nota: e.target.value })} placeholder="Ej. pago del pedido P-002" /></Campo>
          <button className="primario" type="submit">Guardar</button>
        </form>
        <Aviso error={error || caja.error || mov.error} />
        <Tabla filas={mov.data} vacio="Sin movimientos manuales." cols={[
          { k: 'fecha', t: 'Fecha' }, { k: 'cuenta', t: 'Cuenta' },
          { k: 'monto', t: 'Monto', num: true, f: (r) => (r.cuenta === 'bs' ? bs(r.monto) : usd(r.monto)) },
          { k: 'nota', t: 'Nota' },
        ]} />
      </Seccion>
      <Seccion titulo="Préstamos" ayuda="Dinero que nos prestaron para pagar pedidos.">
        <Tabla filas={pre.data} vacio="Sin préstamos." cols={[
          { k: 'fecha', t: 'Fecha' }, { k: 'descripcion', t: 'Descripción' }, { k: 'prestamista', t: 'Prestamista', f: (r) => r.prestamista || 'por definir' },
          { k: 'monto', t: 'Monto', num: true, f: (r) => usd(r.monto) },
          { k: 'devuelto', t: 'Devuelto', num: true, f: (r) => usd(r.devuelto) },
          { k: 'debe', t: 'Debe', num: true, f: (r) => <b className={r.monto - r.devuelto > 0 ? 'alerta' : ''}>{usd(r.monto - r.devuelto)}</b> },
        ]} />
        <p className="ayuda">Para devolver un préstamo ve a <b>Pagos</b>: ahí queda registrado quién pagó y desde qué cuenta.</p>
      </Seccion>
    </>
  )
}
