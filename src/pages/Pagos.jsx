import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tarjeta, Aviso, Guia, Insignia } from '../ui.jsx'
import { hoy, usd, bs, num, cajaUsd } from '../lib.js'

const CUENTAS = { binance: 'Binance ($)', efectivo: 'Efectivo ($)', bs: 'Bolívares (Bs)' }
const TIPOS = { proveedor: 'Compra a proveedor', deuda: 'Pago de deuda', otro: 'Otro pago' }

const fuenteTexto = (p) =>
  p.fuente === 'caja' ? 'De la caja · ' + (CUENTAS[p.cuenta] || p.cuenta)
    : p.fuente === 'socio' ? 'Lo puso ' + (p.pagado_por || 'un socio')
      : p.fuente === 'prestamo' ? 'Préstamo de ' + (p.pagado_por || 'un prestamista') : '—'

export default function Pagos() {
  const { tasa, socios, miSocio } = useApp()
  const pagos = useQuery(() => supabase.from('pagos').select('*').order('fecha', { ascending: false }).order('id', { ascending: false }), [])
  const pre = useQuery(() => supabase.from('prestamos').select('*').order('fecha'), [])
  const caja = useQuery(() => supabase.from('caja_v').select('*'), [])
  const ped = useQuery(() => supabase.from('pedidos').select('codigo').order('codigo'), [])
  const [abierto, setAbierto] = useState(null)       // { tipo: 'deuda'|'pendiente', id }
  const [f, setF] = useState({ cuenta: 'efectivo', monto: '', fecha: hoy(), socio: miSocio?.nombre || '' })
  const [nuevo, setNuevo] = useState({ concepto: '', monto: '', tipo: 'proveedor', pedido: '' })
  const [filtro, setFiltro] = useState({ pedido: '', tipo: '' })
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const saldo = (c) => num(caja.data.find((x) => x.cuenta === c)?.saldo)
  const tb = num(tasa?.binance)
  const saldoUsd = (c) => (c === 'bs' ? (tb > 0 ? saldo('bs') / tb : 0) : saldo(c))
  const disponible = cajaUsd(caja.data, tb)
  const deudas = pre.data.filter((p) => num(p.monto) - num(p.devuelto) > 0.005)
  const deudaTotal = deudas.reduce((a, p) => a + num(p.monto) - num(p.devuelto), 0)
  const pendientes = pagos.data.filter((p) => p.estado === 'pendiente')
  const pendienteTotal = pendientes.reduce((a, p) => a + num(p.monto), 0)
  const hechos = pagos.data.filter((p) => p.estado === 'pagado')
    .filter((p) => (!filtro.pedido || p.pedido_codigo === filtro.pedido) && (!filtro.tipo || p.tipo === filtro.tipo))
  const recargar = () => { pagos.recargar(); pre.recargar(); caja.recargar() }

  // monto que sale de la cuenta (en Bs si es la cuenta de bolívares)
  const montoCuenta = (cuenta, usdMonto) => {
    if (cuenta !== 'bs') return num(usdMonto)
    return Math.min(Math.round(num(usdMonto) * tb * 100) / 100, saldo('bs'))
  }

  const abrir = (tipo, id, monto) => {
    setAbierto({ tipo, id }); setMsg({ error: '', ok: '' })
    setF({ cuenta: 'efectivo', monto: num(monto).toFixed(2), fecha: hoy(), socio: miSocio?.nombre || socios[0] || '' })
  }

  const pagarDeuda = async (e, p) => {
    e.preventDefault()
    if (f.cuenta === 'bs' && !tb) return setMsg({ error: 'Registra primero la tasa del día para pagar en bolívares.', ok: '' })
    if (num(f.monto) > saldoUsd(f.cuenta) + 0.005) return setMsg({ error: `En esa cuenta solo hay ${usd(saldoUsd(f.cuenta))}.`, ok: '' })
    const { error } = await supabase.rpc('pagar_deuda', {
      p_prestamo: p.id, p_monto_usd: num(f.monto), p_cuenta: f.cuenta, p_monto_cuenta: montoCuenta(f.cuenta, f.monto), p_fecha: f.fecha,
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pago de ${usd(f.monto)} a ${p.prestamista || 'prestamista'} registrado.` })
    setAbierto(null); recargar()
  }

  const pagarPendiente = async (e, p) => {
    e.preventDefault()
    const deCaja = f.cuenta !== 'socio'
    if (deCaja && f.cuenta === 'bs' && !tb) return setMsg({ error: 'Registra primero la tasa del día para pagar en bolívares.', ok: '' })
    if (deCaja && num(p.monto) > saldoUsd(f.cuenta) + 0.005) return setMsg({ error: `En esa cuenta solo hay ${usd(saldoUsd(f.cuenta))}.`, ok: '' })
    const { error } = await supabase.rpc('pagar_pendiente', {
      p_id: p.id, p_cuenta: f.cuenta, p_monto_cuenta: deCaja ? montoCuenta(f.cuenta, p.monto) : null,
      p_pagado_por: deCaja ? null : f.socio, p_fecha: f.fecha,
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: 'Pago registrado.' }); setAbierto(null); recargar()
  }

  const anotar = async (e) => {
    e.preventDefault()
    const { error } = await supabase.from('pagos').insert({
      tipo: nuevo.tipo, concepto: nuevo.concepto.trim(), monto: num(nuevo.monto), pedido_codigo: nuevo.pedido || null, estado: 'pendiente', fecha: hoy(),
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setNuevo({ concepto: '', monto: '', tipo: 'proveedor', pedido: '' }); setMsg({ error: '', ok: 'Pago pendiente anotado.' }); pagos.recargar()
  }

  const borrar = async (p) => {
    if (!window.confirm(`¿Eliminar el pago pendiente "${p.concepto}"?`)) return
    const { error } = await supabase.from('pagos').delete().eq('id', p.id)
    if (error) setMsg({ error: error.message, ok: '' }); else pagos.recargar()
  }

  const formPago = (onSubmit, mostrarMonto, children) => (
    <form className="form cobrar-form" onSubmit={onSubmit}>
      <Campo label="Fecha del pago"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
      {mostrarMonto && <Campo label="Monto a pagar ($)"><input type="number" step="0.01" min="0.01" value={f.monto} onChange={(e) => setF({ ...f, monto: e.target.value })} required /></Campo>}
      {children}
    </form>
  )

  return (
    <>
      <Guia>Aquí queda <b>toda la plata que sale</b>: lo que se le paga al proveedor por cada pedido y lo que se devuelve de los préstamos. Cualquier socio puede ver quién puso qué y de dónde salió el dinero.</Guia>
      <Aviso {...msg} error={msg.error || pagos.error || pre.error || caja.error} />

      <div className="tarjetas">
        <Tarjeta titulo="Dinero disponible" valor={usd(disponible)} nota="Binance + efectivo + Bs (a Binance)" tono="bueno" />
        <Tarjeta titulo="Deuda con prestamistas" valor={usd(deudaTotal)} tono={deudaTotal > 0 ? 'malo' : ''} nota={deudas.length ? `${deudas.length} préstamo(s) por devolver` : 'Sin deudas'} />
        <Tarjeta titulo="Pagos pendientes" valor={usd(pendienteTotal)} tono={pendienteTotal > 0 ? 'malo' : ''} nota={`${pendientes.length} por pagar`} />
      </div>

      <Seccion titulo="Deudas por devolver" ayuda="Dinero que nos prestaron. Al pagar, sale de la cuenta que elijas y queda en el historial.">
        {!deudas.length && <p className="vacio">No hay deudas pendientes. 🎉</p>}
        {deudas.map((p) => {
          const debe = num(p.monto) - num(p.devuelto)
          return (
            <article key={p.id} className="pedido">
              <header>
                <div><b>{p.prestamista || 'Prestamista por definir'}</b><br /><small className="ayuda">{p.descripcion} · {p.fecha}</small></div>
                <div>Prestado {usd(p.monto)} · devuelto {usd(p.devuelto)}</div>
                <div className="debe-grande">Debemos <b>{usd(debe)}</b></div>
                <button className="primario" onClick={() => (abierto?.id === p.id && abierto.tipo === 'deuda' ? setAbierto(null) : abrir('deuda', p.id, debe))}>Pagar</button>
              </header>
              {abierto?.tipo === 'deuda' && abierto.id === p.id &&
                formPago((e) => pagarDeuda(e, p), true, <>
                  <Campo label="Pagar desde" ayuda={`Disponible: ${usd(saldoUsd(f.cuenta))}`}>
                    <select value={f.cuenta} onChange={(e) => setF({ ...f, cuenta: e.target.value })}>
                      {Object.entries(CUENTAS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
                    </select>
                  </Campo>
                  {f.cuenta === 'bs' && <Campo label="Saldrán de la cuenta"><input readOnly value={bs(montoCuenta('bs', f.monto))} /></Campo>}
                  <button className="primario" type="submit">Confirmar pago</button>
                </>)}
            </article>
          )
        })}
      </Seccion>

      <Seccion titulo="Pagos pendientes" ayuda="Pagos que todavía no hemos hecho (por ejemplo, un proveedor al que se le paga después).">
        {!pendientes.length && <p className="vacio">No hay pagos pendientes.</p>}
        {pendientes.map((p) => (
          <article key={p.id} className="pedido">
            <header>
              <div><b>{p.concepto}</b><br /><small className="ayuda">{TIPOS[p.tipo]}{p.pedido_codigo ? ' · pedido ' + p.pedido_codigo : ''} · anotado el {p.fecha}</small></div>
              <div className="debe-grande"><b>{usd(p.monto)}</b></div>
              <span>
                <button className="primario" onClick={() => (abierto?.id === p.id && abierto.tipo === 'pendiente' ? setAbierto(null) : abrir('pendiente', p.id, p.monto))}>Pagar</button>{' '}
                <button onClick={() => borrar(p)}>Eliminar</button>
              </span>
            </header>
            {abierto?.tipo === 'pendiente' && abierto.id === p.id &&
              formPago((e) => pagarPendiente(e, p), false, <>
                <Campo label="¿De dónde sale el dinero?" ayuda={f.cuenta !== 'socio' ? `Disponible: ${usd(saldoUsd(f.cuenta))}` : ''}>
                  <select value={f.cuenta} onChange={(e) => setF({ ...f, cuenta: e.target.value })}>
                    {Object.entries(CUENTAS).map(([k, v]) => <option key={k} value={k}>De la caja · {v}</option>)}
                    <option value="socio">Un socio lo pagó con su dinero</option>
                  </select>
                </Campo>
                {f.cuenta === 'socio' && (
                  <Campo label="¿Qué socio?">
                    <select value={f.socio} onChange={(e) => setF({ ...f, socio: e.target.value })} required>
                      {socios.map((s) => <option key={s}>{s}</option>)}
                    </select>
                  </Campo>
                )}
                <button className="primario" type="submit">Confirmar pago</button>
              </>)}
          </article>
        ))}
        <h3>Anotar un pago pendiente</h3>
        <form className="form" onSubmit={anotar}>
          <Campo label="¿Qué hay que pagar?"><input value={nuevo.concepto} onChange={(e) => setNuevo({ ...nuevo, concepto: e.target.value })} placeholder="Ej. Pago al proveedor de la compra 4" required /></Campo>
          <Campo label="Monto ($)"><input type="number" step="0.01" min="0.01" value={nuevo.monto} onChange={(e) => setNuevo({ ...nuevo, monto: e.target.value })} required /></Campo>
          <Campo label="Tipo">
            <select value={nuevo.tipo} onChange={(e) => setNuevo({ ...nuevo, tipo: e.target.value })}>
              <option value="proveedor">Compra a proveedor</option><option value="otro">Otro pago</option>
            </select>
          </Campo>
          <Campo label="Pedido (opcional)">
            <select value={nuevo.pedido} onChange={(e) => setNuevo({ ...nuevo, pedido: e.target.value })}>
              <option value="">—</option>{ped.data.map((p) => <option key={p.codigo}>{p.codigo}</option>)}
            </select>
          </Campo>
          <button className="primario" type="submit">Anotar</button>
        </form>
      </Seccion>

      <Seccion titulo="Historial de pagos" ayuda="Todo lo que ya se pagó, con quién puso el dinero. Es el registro para que todos los socios vean lo mismo."
        acciones={
          <div className="filtros">
            <select value={filtro.pedido} onChange={(e) => setFiltro({ ...filtro, pedido: e.target.value })}>
              <option value="">Todos los pedidos</option>{ped.data.map((p) => <option key={p.codigo}>{p.codigo}</option>)}
            </select>
            <select value={filtro.tipo} onChange={(e) => setFiltro({ ...filtro, tipo: e.target.value })}>
              <option value="">Todos los tipos</option>{Object.entries(TIPOS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </div>
        }>
        {!hechos.length ? <p className="vacio">Todavía no hay pagos registrados.</p> : (
          <div className="tabla-wrap">
            <table>
              <thead><tr><th>Fecha</th><th>Concepto</th><th>Tipo</th><th>De dónde salió</th><th className="num">Monto</th><th>Registró</th></tr></thead>
              <tbody>
                {hechos.map((p) => (
                  <tr key={p.id}>
                    <td>{p.fecha_pago || p.fecha}</td>
                    <td>{p.concepto}</td>
                    <td><Insignia tono={p.tipo === 'deuda' ? 'warn' : ''}>{TIPOS[p.tipo]}</Insignia></td>
                    <td>{fuenteTexto(p)}</td>
                    <td className="num"><b>{usd(p.monto)}</b></td>
                    <td>{(p.registrado_por || '').split('@')[0] || '—'}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot><tr><td colSpan={4}><b>Total pagado</b></td><td className="num"><b>{usd(hechos.reduce((a, p) => a + num(p.monto), 0))}</b></td><td /></tr></tfoot>
            </table>
          </div>
        )}
      </Seccion>
    </>
  )
}
