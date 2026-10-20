import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Tabla, Tarjeta, Aviso } from '../ui.jsx'
import { hoy, usd, bs, num } from '../lib.js'

export default function PorCobrar() {
  const lista = useQuery(() => supabase.from('por_cobrar_v').select('*').order('vence', { ascending: true, nullsFirst: false }), [])
  const [abierto, setAbierto] = useState(null)
  const [f, setF] = useState({ cuenta: 'efectivo', monto: '', fecha: hoy(), tasa: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const total = lista.data.reduce((a, r) => a + num(r.pendiente_usd), 0)
  const vencido = lista.data.filter((r) => r.vence && r.vence < hoy()).reduce((a, r) => a + num(r.pendiente_usd), 0)
  const esteMes = lista.data.filter((r) => r.vence && r.vence >= hoy()).reduce((a, r) => a + num(r.pendiente_usd), 0)

  const abrir = (r) => { setAbierto(r.id); setF({ cuenta: 'efectivo', monto: num(r.pendiente_usd).toFixed(2), fecha: hoy(), tasa: '' }); setMsg({ error: '', ok: '' }) }

  const cobrar = async (e, r) => {
    e.preventDefault()
    const { error } = await supabase.from('cobros').insert({
      venta_id: r.id, fecha: f.fecha, cuenta: f.cuenta, monto: num(f.monto),
      tasa_binance: f.cuenta === 'bs' && f.tasa ? num(f.tasa) : null,
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Cobro registrado a ${r.cliente}.` })
    setAbierto(null); lista.recargar()
  }

  return (
    <>
      <Seccion titulo="Cuentas por cobrar" ayuda="Ventas con saldo pendiente. Los Bs se valoran a la tasa Binance de la venta (o la que indiques al cobrar).">
        <div className="tarjetas">
          <Tarjeta titulo="Total por cobrar" valor={usd(total)} nota={`${lista.data.length} ventas`} />
          <Tarjeta titulo="Vencido" valor={usd(vencido)} tono={vencido > 0 ? 'malo' : ''} />
          <Tarjeta titulo="Por vencer" valor={usd(esteMes)} />
        </div>
        <Aviso {...msg} error={msg.error || lista.error} />
        {!lista.data.length && <p className="vacio">No hay cuentas por cobrar.</p>}
        {lista.data.length > 0 && (
          <div className="tabla-wrap"><table>
            <thead><tr><th>Vence</th><th>Cliente</th><th>Perfume</th><th className="num">Valor $</th><th className="num">Cobrado</th><th className="num">Pendiente</th><th /></tr></thead>
            <tbody>
              {lista.data.map((r) => (
                <React.Fragment key={r.id}>
                  <tr>
                    <td className={r.vence && r.vence < hoy() ? 'vencido' : ''}>{r.vence || 'sin fecha'}</td>
                    <td>{r.cliente}</td><td>{r.nombre}{r.unidades > 1 ? ` ×${r.unidades}` : ''}</td>
                    <td className="num">{usd(r.valor_usd)}</td><td className="num">{usd(r.cobrado_usd)}</td>
                    <td className="num"><b>{usd(r.pendiente_usd)}</b></td>
                    <td><button onClick={() => (abierto === r.id ? setAbierto(null) : abrir(r))}>Cobrar</button></td>
                  </tr>
                  {abierto === r.id && (
                    <tr><td colSpan={7}>
                      <form className="form cobrar-form" onSubmit={(e) => cobrar(e, r)}>
                        <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
                        <Campo label="Cuenta">
                          <select value={f.cuenta} onChange={(e) => setF({ ...f, cuenta: e.target.value })}>
                            <option value="efectivo">$ efectivo</option><option value="binance">$ Binance</option><option value="bs">Bs</option>
                          </select>
                        </Campo>
                        <Campo label={f.cuenta === 'bs' ? 'Monto en Bs' : 'Monto $'} ayuda={f.cuenta === 'bs' ? 'Ej. pendiente × tasa Binance' : ''}>
                          <input type="number" step="0.01" min="0" value={f.monto} onChange={(e) => setF({ ...f, monto: e.target.value })} required />
                        </Campo>
                        {f.cuenta === 'bs' && <Campo label="Tasa Binance del día" ayuda="Vacío = la de la venta"><input type="number" step="0.01" value={f.tasa} onChange={(e) => setF({ ...f, tasa: e.target.value })} /></Campo>}
                        <button className="primario" type="submit">Guardar cobro</button>
                      </form>
                    </td></tr>
                  )}
                </React.Fragment>
              ))}
            </tbody>
          </table></div>
        )}
      </Seccion>
    </>
  )
}
