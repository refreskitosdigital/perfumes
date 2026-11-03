import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Tarjeta, Aviso, Guia } from '../ui.jsx'
import { hoy, usd, bs, num } from '../lib.js'

const TIPOS = { bonificacion: '🎁 Bonificación', reparto: '💵 Reparto de ganancia', otro: '🧾 Otro pago' }
const CUENTAS = { efectivo: '$ efectivo', binance: '$ Binance', bs: 'Bolívares (banco)' }

// Pagos a los socios: bonificaciones, reparto de ganancia u otros. Lo que se paga sale de la caja.
export default function PagosSocios() {
  const { socios, tasa } = useApp()
  const ret = useQuery(() => supabase.from('retiros_socios').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }), [])
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const [f, setF] = useState({ fecha: hoy(), socio: '', tipo: 'bonificacion', cuenta: 'efectivo', monto: '', tasa: '', nota: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const set = (k) => (e) => setF({ ...f, [k]: e.target.value })
  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)
  const esBs = f.cuenta === 'bs'
  const tasaUso = esBs ? (num(f.tasa) || num(tasa?.bcv)) : 1
  const equivale = esBs ? (tasaUso > 0 ? num(f.monto) / tasaUso : 0) : num(f.monto)

  const guardar = async (e) => {
    e.preventDefault()
    if (!f.socio) return setMsg({ error: 'Elige a qué socio se le paga.', ok: '' })
    if (!(num(f.monto) > 0)) return setMsg({ error: 'Escribe el monto.', ok: '' })
    if (esBs && !(tasaUso > 0)) return setMsg({ error: 'Para pagos en bolívares escribe la tasa con la que se valoran en dólares.', ok: '' })
    if (num(f.monto) > saldo(f.cuenta) + 0.005 && !window.confirm(`La caja (${CUENTAS[f.cuenta]}) tiene ${esBs ? bs(saldo('bs')) : usd(saldo(f.cuenta))} y estás pagando más que eso. ¿Guardarlo igual?`)) return
    const { error } = await supabase.from('retiros_socios').insert({
      fecha: f.fecha, socio: f.socio, tipo: f.tipo, cuenta: f.cuenta, monto: num(f.monto),
      tasa: esBs ? tasaUso : null, monto_usd: Math.round(equivale * 100) / 100, nota: f.nota.trim() || null,
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pago de ${usd(equivale)} a ${f.socio} registrado y descontado de la caja.` })
    setF({ ...f, monto: '', nota: '' }); ret.recargar(); caja.recargar()
  }
  const borrar = async (r) => {
    if (!window.confirm(`¿Eliminar el pago de ${usd(r.monto_usd)} a ${r.socio}? El dinero vuelve a la caja.`)) return
    const { error } = await supabase.from('retiros_socios').delete().eq('id', r.id)
    if (error) return setMsg({ error: error.message, ok: '' })
    ret.recargar(); caja.recargar()
  }
  const total = (n) => ret.data.filter((r) => r.socio === n).reduce((a, r) => a + num(r.monto_usd), 0)

  return (
    <>
      <Guia>Aquí anotas lo que se le paga a un socio (una <b>bonificación</b> o su <b>parte de la ganancia</b>). Ese dinero se <b>descuenta de la caja</b> y queda registrado en lo que ese socio ya recibió.</Guia>
      <Seccion titulo="Pagar a un socio">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Fecha"><input type="date" value={f.fecha} onChange={set('fecha')} required /></Campo>
            <Campo label="Socio">
              <select value={f.socio} onChange={set('socio')} required><option value="">—</option>{socios.map((n) => <option key={n}>{n}</option>)}</select>
            </Campo>
            <Campo label="Tipo"><select value={f.tipo} onChange={set('tipo')}>{Object.entries(TIPOS).map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select></Campo>
            <Campo label="Sale de" ayuda={`En caja: ${esBs ? bs(saldo('bs')) : usd(saldo(f.cuenta))}`}>
              <select value={f.cuenta} onChange={set('cuenta')}>{Object.entries(CUENTAS).map(([k, t]) => <option key={k} value={k}>{t}</option>)}</select>
            </Campo>
            <Campo label={esBs ? 'Monto (Bs)' : 'Monto ($)'}><input type="number" step="0.01" min="0.01" inputMode="decimal" value={f.monto} onChange={set('monto')} required /></Campo>
            {esBs && <Campo label="Tasa BCV $" ayuda={tasaUso > 0 && num(f.monto) > 0 ? `= ${usd(equivale)}` : ''}><input type="number" step="0.01" min="0.01" value={f.tasa} placeholder={tasa?.bcv ? String(tasa.bcv) : ''} onChange={set('tasa')} /></Campo>}
            <Campo label="Nota (opcional)"><input value={f.nota} onChange={set('nota')} placeholder="Ej: bonificación por el lote 3" /></Campo>
          </div>
          <button className="primario" type="submit">Guardar pago</button>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Lo que ha recibido cada socio">
        <div className="tarjetas">{socios.map((n) => <Tarjeta key={n} titulo={n} valor={usd(total(n))} nota="Reparto y bonificaciones" />)}</div>
      </Seccion>

      <Seccion titulo="Historial de pagos a socios">
        <Aviso error={ret.error} />
        <Tabla filas={ret.data} vacio="Todavía no hay pagos a socios." cols={[
          { k: 'fecha', t: 'Fecha', f: (r) => String(r.fecha).slice(0, 10) },
          { k: 'socio', t: 'Socio' },
          { k: 'tipo', t: 'Tipo', f: (r) => TIPOS[r.tipo] || r.tipo },
          { k: 'cuenta', t: 'Salió de', f: (r) => CUENTAS[r.cuenta] },
          { k: 'monto', t: 'Monto', num: true, f: (r) => (r.cuenta === 'bs' ? `${bs(r.monto)} a ${num(r.tasa)}` : usd(r.monto)) },
          { k: 'monto_usd', t: 'En $', num: true, f: (r) => usd(r.monto_usd) },
          { k: 'nota', t: 'Nota' },
          { k: 'x', t: '', f: (r) => <button onClick={() => borrar(r)} aria-label="Eliminar pago">🗑️</button> },
        ]} />
      </Seccion>
    </>
  )
}
