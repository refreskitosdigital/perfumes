import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Tarjeta, Aviso, Guia } from '../ui.jsx'
import { hoy, usd, bs, num, cajaUsd } from '../lib.js'

export default function Caja() {
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const mov = useQuery(() => supabase.from('movimientos').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }), [])
  const [f, setF] = useState({ fecha: hoy(), cuenta: 'binance', tipo: 'sale', monto: '', nota: '' })
  const [error, setError] = useState('')
  const pre = useQuery(() => supabase.from('prestamos').select('*').order('fecha', { ascending: false }), [])
  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)
  const { tasas, tasa } = useApp()
  const conv = useQuery(() => supabase.from('conversiones_v').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }), [])
  const bcvRef = num(tasas.data.find((r) => num(r.bcv) > 0)?.bcv)
  const [c, setC] = useState({ fecha: hoy(), bs: '', divisa: '', cuenta: 'binance', tasa_bcv: bcvRef || '', nota: '' })
  const [errConv, setErrConv] = useState('')
  const esperado = num(c.bs) > 0 && num(c.tasa_bcv) > 0 ? num(c.bs) / num(c.tasa_bcv) : 0
  const mermaPrev = esperado > 0 && num(c.divisa) > 0 ? esperado - num(c.divisa) : null
  const mermaTotal = conv.data.reduce((a, r) => a + num(r.merma_usd), 0)
  const bsSaldo = saldo('bs')
  const bsEstimado = num(tasa?.binance) > 0 ? bsSaldo / num(tasa.binance) : 0
  const totalWallet = cajaUsd(caja.data, tasa?.binance)

  const [conteo, setConteo] = useState({ bs: '', efectivo: '', binance: '' })
  const [msgConteo, setMsgConteo] = useState({ error: '', ok: '' })
  const difs = ['efectivo', 'binance', 'bs'].map((k) => {
    const real = conteo[k] === '' ? null : Number(conteo[k])
    return { k, real, sistema: saldo(k), dif: real == null ? null : Math.round((real - saldo(k)) * 100) / 100 }
  })
  const ajustar = async () => {
    const filas = difs.filter((d) => d.dif != null && Math.abs(d.dif) >= 0.01)
    if (!filas.length) return setMsgConteo({ error: 'No hay diferencias que ajustar.', ok: '' })
    if (!window.confirm('Se registrará un movimiento de ajuste por cada diferencia para que la caja quede igual al conteo real. ¿Continuar?')) return
    const { error } = await supabase.from('movimientos').insert(filas.map((d) => ({ fecha: hoy(), cuenta: d.k, monto: d.dif, nota: 'Ajuste por conteo real de la caja' })))
    if (error) return setMsgConteo({ error: error.message, ok: '' })
    setMsgConteo({ error: '', ok: 'Caja ajustada al conteo real.' }); setConteo({ bs: '', efectivo: '', binance: '' }); caja.recargar(); mov.recargar()
  }
  const convertir = async (e) => {
    e.preventDefault()
    if (num(c.bs) > bsSaldo + 0.005 && !window.confirm(`Solo hay ${bs(bsSaldo)} en bolívares. ¿Registrar la conversión de todos modos?`)) return
    const { error } = await supabase.from('conversiones').insert({ fecha: c.fecha, bs: Number(c.bs), divisa: Number(c.divisa), cuenta: c.cuenta, tasa_bcv: Number(c.tasa_bcv), nota: c.nota || null })
    setErrConv(error ? (/conversiones/.test(error.message) ? 'Falta ejecutar migracion_v11.sql en Supabase.' : error.message) : '')
    if (!error) { setC({ ...c, bs: '', divisa: '', nota: '' }); caja.recargar(); conv.recargar() }
  }
  const quitarConv = async (id) => {
    if (!window.confirm('¿Eliminar esta conversión? Los Bs vuelven a la caja y la divisa sale.')) return
    const { error } = await supabase.from('conversiones').delete().eq('id', id)
    setErrConv(error ? error.message : '')
    if (!error) { caja.recargar(); conv.recargar() }
  }

  const guardar = async (e) => {
    e.preventDefault()
    const m = Math.abs(Number(f.monto)) * (f.tipo === 'sale' ? -1 : 1)
    const { error } = await supabase.from('movimientos').insert({ fecha: f.fecha, cuenta: f.cuenta, monto: m, nota: f.nota })
    setError(error ? error.message : '')
    if (!error) { setF({ ...f, monto: '', nota: '' }); caja.recargar(); mov.recargar() }
  }

  const sobrante = mov.data.filter((m) => m.concilia)
  const sumaConcilia = (c) => sobrante.filter((m) => m.cuenta === c).reduce((a, m) => a + num(m.monto), 0)

  return (
    <>
      <Seccion titulo="Saldos" ayuda="Cobros por cuenta, menos gastos y pagos, más los movimientos que registres aquí. Todo en dólares; los Bs se muestran en Bs.">
        <div className="tarjetas">
          <Tarjeta titulo="Efectivo ($)" valor={usd(saldo('efectivo'))} />
          <Tarjeta titulo="Binance ($)" valor={usd(saldo('binance'))} />
          <Tarjeta titulo="Bolívares (Bs)" valor={bs(bsSaldo)} nota={bsSaldo ? `≈ ${usd(bsEstimado)} a Binance (estimado)` : 'Sin bolívares por convertir'} />
          <Tarjeta titulo={bsSaldo > 0.005 ? 'Wallet total (estimado)' : 'Wallet total'} valor={usd(totalWallet)} tono="bueno"
            nota={bsSaldo > 0.005 ? 'Incluye Bs sin convertir a tasa Binance. Será exacto al convertirlos.' : 'Todo en divisa: monto exacto'} />
        </div>
        {sobrante.length > 0 && (
          <div className="aviso-inciso">
            <b>Inciso · Sobrante por conciliar:</b>{' '}
            {sobrante.map((m) => `${m.cuenta === 'bs' ? bs(m.monto) : usd(m.monto)} en ${m.cuenta === 'bs' ? 'banco' : m.cuenta}`).join(' · ')}.
            {' '}Es dinero que hay en la caja pero que no sale de las ventas registradas. Está incluido en los saldos de arriba y se muestra aparte para buscar de dónde viene.
          </div>
        )}
      </Seccion>
      <Seccion titulo="Conteo real de la caja" ayuda="Escribe lo que de verdad tienes hoy (banco en Bs, efectivo y Binance). Ves la diferencia contra el sistema y, si quieres, la ajustas con un solo botón. Deja vacía la cuenta que no quieras contar.">
        <div className="form">
          <Campo label="Banco (Bs)"><input type="number" step="0.01" value={conteo.bs} onChange={(e) => setConteo({ ...conteo, bs: e.target.value })} /></Campo>
          <Campo label="Efectivo ($)"><input type="number" step="0.01" value={conteo.efectivo} onChange={(e) => setConteo({ ...conteo, efectivo: e.target.value })} /></Campo>
          <Campo label="Binance ($)"><input type="number" step="0.01" value={conteo.binance} onChange={(e) => setConteo({ ...conteo, binance: e.target.value })} /></Campo>
        </div>
        <Tabla filas={difs.filter((d) => d.real != null)} vacio="Escribe tu conteo para compararlo con el sistema." cols={[
          { k: 'k', t: 'Cuenta', f: (d) => ({ bs: 'Banco (Bs)', efectivo: 'Efectivo', binance: 'Binance' }[d.k]) },
          { k: 'sistema', t: 'Sistema', num: true, f: (d) => (d.k === 'bs' ? bs(d.sistema) : usd(d.sistema)) },
          { k: 'real', t: 'Conteo real', num: true, f: (d) => (d.k === 'bs' ? bs(d.real) : usd(d.real)) },
          { k: 'dif', t: 'Diferencia', num: true, f: (d) => <b className={Math.abs(d.dif) < 0.01 ? 'bueno' : 'alerta'}>{Math.abs(d.dif) < 0.01 ? 'Cuadra' : (d.dif > 0 ? '+' : '') + (d.k === 'bs' ? bs(d.dif) : usd(d.dif))}</b> },
        ]} />
        <Aviso {...msgConteo} />
        <button className="primario" onClick={ajustar} disabled={!difs.some((d) => d.dif != null && Math.abs(d.dif) >= 0.01)}>Ajustar la caja al conteo real</button>
      </Seccion>
      <Seccion titulo="Convertir bolívares en divisa" ayuda="Cuando compras divisa con los Bs que cobraste, anótalo aquí: los Bs salen de la caja, la divisa entra y se calcula cuánto se perdió en el cambio (merma).">
        <Guia>La <b>merma</b> compara lo que esos Bs valían a la <b>BCV $</b> del día del cobro con la divisa que realmente recibiste. Ejemplo: 3.600 Bs a BCV 36 = $100; si compras $90, la merma es $10. La merma se resta de la ganancia neta.</Guia>
        <form className="form" onSubmit={convertir}>
          <Campo label="Fecha"><input type="date" value={c.fecha} onChange={(e) => setC({ ...c, fecha: e.target.value })} required /></Campo>
          <Campo label="Bs entregados"><input type="number" step="0.01" min="0.01" value={c.bs} onChange={(e) => setC({ ...c, bs: e.target.value })} required /></Campo>
          <Campo label="Divisa recibida ($)"><input type="number" step="0.01" min="0.01" value={c.divisa} onChange={(e) => setC({ ...c, divisa: e.target.value })} required /></Campo>
          <Campo label="Entró a">
            <select value={c.cuenta} onChange={(e) => setC({ ...c, cuenta: e.target.value })}><option value="binance">Binance</option><option value="efectivo">Efectivo</option></select>
          </Campo>
          <Campo label="BCV $ de referencia (Bs por $)" ayuda={bcvRef ? '' : 'Carga la BCV $ en Tasas para que aparezca sola.'}>
            <input type="number" step="0.01" min="0.01" value={c.tasa_bcv} onChange={(e) => setC({ ...c, tasa_bcv: e.target.value })} required />
          </Campo>
          <Campo label="Nota"><input value={c.nota} onChange={(e) => setC({ ...c, nota: e.target.value })} placeholder="Opcional" /></Campo>
          <button className="primario" type="submit">Registrar conversión</button>
        </form>
        {mermaPrev != null && (
          <p className="ayuda">Esperado a BCV: <b>{usd(esperado)}</b> · Recibido: <b>{usd(c.divisa)}</b> · Merma: <b className={mermaPrev > 0 ? 'alerta' : 'bueno'}>{usd(mermaPrev)}</b> ({esperado ? ((mermaPrev / esperado) * 100).toFixed(1) : 0} %) · Tasa real {num(c.divisa) ? (num(c.bs) / num(c.divisa)).toLocaleString('es-VE', { maximumFractionDigits: 2 }) : '—'} Bs/$</p>
        )}
        <Aviso error={errConv || conv.error} />
        <Tabla filas={conv.data} vacio="Aún no has convertido bolívares." cols={[
          { k: 'fecha', t: 'Fecha' },
          { k: 'bs', t: 'Bs', num: true, f: (r) => bs(r.bs) },
          { k: 'divisa', t: 'Recibido', num: true, f: (r) => usd(r.divisa) + ' · ' + r.cuenta },
          { k: 'esperado_usd', t: 'Esperado (BCV)', num: true, f: (r) => usd(r.esperado_usd) },
          { k: 'merma_usd', t: 'Merma', num: true, f: (r) => <b className={num(r.merma_usd) > 0 ? 'alerta' : ''}>{usd(r.merma_usd)} ({(num(r.merma_pct) * 100).toFixed(1)} %)</b> },
          { k: 'nota', t: 'Nota' },
          { k: 'x', t: '', f: (r) => <button onClick={() => quitarConv(r.id)} aria-label="Eliminar conversión">🗑️</button> },
        ]} />
        {conv.data.length > 0 && <p className="ayuda">Merma acumulada: <b className="alerta">{usd(mermaTotal)}</b></p>}
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
