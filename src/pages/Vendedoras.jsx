import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Tarjeta, Aviso, Guia, Insignia } from '../ui.jsx'
import { hoy, usd, num } from '../lib.js'

const ESTADOS = { pendiente: ['warn', 'Por aprobar'], aprobado: ['ok', 'Aprobado'], entregado: ['ok', 'Entregado'], rechazado: ['', 'Rechazado'] }
const urlVend = (import.meta.env.VITE_URL_VENDEDORAS || '').replace(/\/+$/, '')

export default function Vendedoras() {
  const { perfumes } = useApp()
  const vend = useQuery(() => supabase.from('vendedoras').select('id,nombre,usuario,activa,bloqueado_hasta').order('nombre'), [])
  const ped = useQuery(() => supabase.from('vendedora_pedidos_v').select('*').order('creado', { ascending: false }), [])
  const items = useQuery(() => supabase.from('pedidos_vendedora_items').select('*').order('id'), [])
  const inv = useQuery(() => supabase.from('inventario_v').select('id,nombre,stock').lt('stock', 0), [])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [editar, setEditar] = useState(null)
  const [rechazando, setRechazando] = useState(null)
  const [pagando, setPagando] = useState(null)
  const [pago, setPago] = useState({ monto: '', cuenta: 'efectivo', fecha: hoy() })

  const ok = (m) => setMsg({ error: '', ok: m })
  const fallo = (e) => setMsg({ error: e.message || String(e), ok: '' })
  const recargar = () => { vend.recargar(); ped.recargar(); items.recargar(); inv.recargar() }
  const nombrePerfume = (id) => perfumes.data.find((p) => p.id === id)?.nombre || '—'
  const itemsDe = (id) => items.data.filter((i) => i.pedido_id === id)

  const pendientes = ped.data.filter((p) => p.estado === 'pendiente')
  const vigentes = ped.data.filter((p) => p.estado === 'aprobado' || p.estado === 'entregado')

  const aprobar = async (p) => {
    const { data, error } = await supabase.rpc('vend_aprobar', { p_id: p.id })
    if (error) return fallo(error)
    ok(`Pedido #${p.id} aprobado: se crearon ${data} ventas a precio de consignación para ${p.vendedora}.`); recargar()
  }
  const rechazar = async (p) => {
    const { error } = await supabase.rpc('vend_rechazar', { p_id: p.id, p_nota: rechazando?.nota || '' })
    if (error) return fallo(error)
    ok(`Pedido #${p.id} rechazado.`); setRechazando(null); recargar()
  }
  const guardarVend = async (e) => {
    e.preventDefault()
    const { error } = await supabase.rpc('vend_guardar', {
      p_id: editar.id || null, p_nombre: editar.nombre, p_usuario: editar.usuario, p_pin: editar.pin || '', p_activa: editar.activa,
    })
    if (error) return fallo(/vend_guardar|function/.test(error.message) && /not find|schema cache/.test(error.message) ? new Error('Falta ejecutar migracion_v9.sql en Supabase.') : error)
    ok(editar.id ? 'Vendedora actualizada.' : `Vendedora creada. Dale su usuario "${editar.usuario.toLowerCase()}" y su PIN.`)
    setEditar(null); recargar()
  }
  const recibirPago = async (v) => {
    const { data, error } = await supabase.rpc('vend_recibir_pago', { p_vendedora_id: v.id, p_monto: num(pago.monto), p_cuenta: pago.cuenta, p_fecha: pago.fecha })
    if (error) return fallo(error)
    ok(`Pago de ${usd(data)} de ${v.nombre} registrado en ${pago.cuenta}. Ya figura en Caja y en Por cobrar.`)
    setPagando(null); setPago({ monto: '', cuenta: 'efectivo', fecha: hoy() }); recargar()
  }

  // Estado de cuenta por vendedora
  const cuentas = vend.data.map((v) => {
    const mias = vigentes.filter((p) => p.vendedora_id === v.id)
    const suma = (k) => mias.reduce((a, p) => a + num(p[k]), 0)
    const comisionGanada = mias.reduce((a, p) => a + num(p.ganancia_ganada), 0)
    return {
      ...v, pedidos: mias.length, consigna: suma('total_consigna'), venta: suma('total_venta'), cobrado: suma('cobrado_cliente'),
      pagado: suma('pagado_perfumeria'), debe: suma('debe_perfumeria'), porCobrar: suma('total_venta') - suma('cobrado_cliente'),
      comision: comisionGanada, pendientes: ped.data.filter((p) => p.vendedora_id === v.id && p.estado === 'pendiente').length,
    }
  })
  const totalDebe = cuentas.reduce((a, c) => a + c.debe, 0)
  const totalConsignaPend = cuentas.reduce((a, c) => a + (c.consigna - c.pagado), 0)

  return (
    <>
      <Guia>
        Las vendedoras <b>no reciben mercancía</b>: eligen del catálogo, anotan a cuánto lo venden (nunca menos que tu consignación) y tú <b>apruebas</b> cada pedido.
        Al aprobar, se crea la venta a <b>precio de consignación</b> (lo que ellas te deben) y el perfume que no tengas queda por comprar.
        {urlVend ? <> Su link: <a href={urlVend} target="_blank" rel="noreferrer">{urlVend}</a></> : <> El link aparte se crea como un tercer sitio en Netlify (pasos en el README, "Link de vendedoras").</>}
      </Guia>
      <Aviso {...msg} />

      <Seccion titulo={`Pedidos por aprobar (${pendientes.length})`}>
        {!pendientes.length && <p className="vacio">No hay pedidos esperando.</p>}
        {pendientes.map((p) => (
          <article key={p.id} className="pedido">
            <header>
              <div><b>#{p.id} · {p.vendedora}</b> para <b>{p.cliente}</b>{p.telefono ? ` · ${p.telefono}` : ''}</div>
              <div>Cliente paga <b>{usd(p.total_venta)}</b> · te corresponde <b>{usd(p.total_consigna)}</b> · ella gana <b>{usd(p.ganancia_vendedora)}</b></div>
            </header>
            <ul>{itemsDe(p.id).map((i) => <li key={i.id}>{nombrePerfume(i.perfume_id)} · {i.unidades} u · consigna {usd(i.precio_consigna)} · vende a {usd(i.precio_venta)}</li>)}</ul>
            <p className="ayuda">Pago del cliente: {p.plan === 'contado' ? 'de contado' : p.plan === 'mitades' ? `en 2 partes${p.fecha1 ? ` (${p.fecha1} y ${p.fecha2 || '—'})` : ''}` : 'otro acuerdo'}{p.notas ? ` · ${p.notas}` : ''}</p>
            {rechazando?.id === p.id ? (
              <div className="atajos">
                <input placeholder="Motivo (opcional, ella lo verá)" value={rechazando.nota} onChange={(e) => setRechazando({ ...rechazando, nota: e.target.value })} />
                <button onClick={() => rechazar(p)}>Confirmar rechazo</button><button onClick={() => setRechazando(null)}>Cancelar</button>
              </div>
            ) : (
              <div className="atajos"><button className="primario" onClick={() => aprobar(p)}>✅ Aprobar</button><button onClick={() => setRechazando({ id: p.id, nota: '' })}>Rechazar</button></div>
            )}
          </article>
        ))}
      </Seccion>

      {inv.data.length > 0 && (
        <Seccion titulo="Por comprar para cubrir pedidos aprobados" ayuda="Son perfumes vendidos que todavía no tienes en inventario. Agéndalos en Agenda de pedidos.">
          <Tabla filas={inv.data} cols={[{ k: 'nombre', t: 'Perfume' }, { k: 'stock', t: 'Te faltan', num: true, f: (r) => Math.abs(r.stock) }]} />
        </Seccion>
      )}

      <Seccion titulo="Estado de cuenta por vendedora" ayuda="'Te debe' es la parte de consignación de lo que el cliente ya le pagó a ella, menos lo que ella ya te entregó.">
        <div className="tarjetas">
          <Tarjeta titulo="Te deben las vendedoras" valor={usd(totalDebe)} tono={totalDebe > 0 ? 'malo' : ''} nota="De lo que sus clientes ya pagaron" />
          <Tarjeta titulo="Consignación aún sin cobrar" valor={usd(totalConsignaPend)} nota="Incluye lo que aún no le pagan a ella" />
        </div>
        <Tabla filas={cuentas} vacio="Aún no hay vendedoras. Crea la primera abajo." cols={[
          { k: 'nombre', t: 'Vendedora', f: (c) => <><b>{c.nombre}</b> {c.pendientes > 0 && <Insignia tono="warn">{c.pendientes} por aprobar</Insignia>}</> },
          { k: 'pedidos', t: 'Pedidos', num: true },
          { k: 'venta', t: 'Vendió', num: true, f: (c) => usd(c.venta) },
          { k: 'consigna', t: 'Tu parte', num: true, f: (c) => usd(c.consigna) },
          { k: 'comision', t: 'Su ganancia cobrada', num: true, f: (c) => usd(c.comision) },
          { k: 'porCobrar', t: 'Clientes le deben', num: true, f: (c) => usd(c.porCobrar) },
          { k: 'pagado', t: 'Ya te pagó', num: true, f: (c) => usd(c.pagado) },
          { k: 'debe', t: 'Te debe', num: true, f: (c) => <b className={c.debe > 0.01 ? 'alerta' : ''}>{usd(c.debe)}</b> },
          { k: 'x', t: '', f: (c) => <button onClick={() => { setPagando(pagando === c.id ? null : c.id); setPago({ monto: c.debe > 0 ? c.debe.toFixed(2) : '', cuenta: 'efectivo', fecha: hoy() }) }}>💵 Recibir pago</button> },
        ]} />
        {pagando && (
          <div className="cobrar-form">
            <b>Pago de {vend.data.find((v) => v.id === pagando)?.nombre}</b>
            <div className="form">
              <Campo label="Monto $"><input type="number" step="0.01" min="0" inputMode="decimal" value={pago.monto} onChange={(e) => setPago({ ...pago, monto: e.target.value })} /></Campo>
              <Campo label="Entró a"><select value={pago.cuenta} onChange={(e) => setPago({ ...pago, cuenta: e.target.value })}><option value="efectivo">$ Efectivo</option><option value="binance">$ Binance</option></select></Campo>
              <Campo label="Fecha"><input type="date" value={pago.fecha} onChange={(e) => setPago({ ...pago, fecha: e.target.value })} /></Campo>
            </div>
            <div className="atajos"><button className="primario" onClick={() => recibirPago(vend.data.find((v) => v.id === pagando))}>Registrar pago</button><button onClick={() => setPagando(null)}>Cancelar</button></div>
          </div>
        )}
      </Seccion>

      <Seccion titulo="Historial de pedidos de vendedoras">
        <Tabla filas={ped.data} vacio="Todavía no hay pedidos." cols={[
          { k: 'id', t: '#' }, { k: 'creado', t: 'Fecha', f: (p) => String(p.creado).slice(0, 10) },
          { k: 'vendedora', t: 'Vendedora' }, { k: 'cliente', t: 'Cliente' },
          { k: 'estado', t: 'Estado', f: (p) => <Insignia tono={ESTADOS[p.estado]?.[0]}>{ESTADOS[p.estado]?.[1] || p.estado}</Insignia> },
          { k: 'total_venta', t: 'Venta', num: true, f: (p) => usd(p.total_venta) },
          { k: 'total_consigna', t: 'Tu parte', num: true, f: (p) => usd(p.total_consigna) },
          { k: 'cobrado_cliente', t: 'Cobrado al cliente', num: true, f: (p) => usd(p.cobrado_cliente) },
          { k: 'debe_perfumeria', t: 'Te debe', num: true, f: (p) => (num(p.debe_perfumeria) > 0.01 ? <b className="alerta">{usd(p.debe_perfumeria)}</b> : '') },
        ]} />
      </Seccion>

      <Seccion titulo="Vendedoras con acceso" acciones={<button className="primario" onClick={() => setEditar(editar ? null : { id: null, nombre: '', usuario: '', pin: '', activa: true })}>{editar ? 'Cerrar' : '➕ Nueva vendedora'}</button>}>
        {editar && (
          <form onSubmit={guardarVend}>
            <div className="form">
              <Campo label="Nombre"><input value={editar.nombre} onChange={(e) => setEditar({ ...editar, nombre: e.target.value })} required /></Campo>
              <Campo label="Usuario" ayuda="Letras minúsculas y números, sin espacios"><input value={editar.usuario} onChange={(e) => setEditar({ ...editar, usuario: e.target.value.toLowerCase().replace(/\s/g, '') })} required /></Campo>
              <Campo label={editar.id ? 'PIN nuevo (vacío = no cambia)' : 'PIN (6 a 10 números)'} ayuda="No lo pongas igual al de otra persona"><input inputMode="numeric" pattern="[0-9]*" value={editar.pin} onChange={(e) => setEditar({ ...editar, pin: e.target.value.replace(/\D/g, '') })} required={!editar.id} /></Campo>
              <Campo label="Acceso"><select value={editar.activa ? '1' : '0'} onChange={(e) => setEditar({ ...editar, activa: e.target.value === '1' })}><option value="1">Activo</option><option value="0">Desactivado</option></select></Campo>
            </div>
            <button className="primario" type="submit">{editar.id ? 'Guardar' : 'Crear vendedora'}</button>
          </form>
        )}
        <Aviso error={vend.error || ped.error} />
        <Tabla filas={vend.data} vacio="Aún no hay vendedoras." cols={[
          { k: 'nombre', t: 'Nombre' }, { k: 'usuario', t: 'Usuario' },
          { k: 'activa', t: 'Acceso', f: (v) => (v.bloqueado_hasta && new Date(v.bloqueado_hasta) > new Date() ? <Insignia tono="warn">Bloqueada por intentos</Insignia> : v.activa ? <Insignia tono="ok">Activo</Insignia> : <Insignia>Desactivado</Insignia>) },
          { k: 'x', t: '', f: (v) => <button onClick={() => setEditar({ id: v.id, nombre: v.nombre, usuario: v.usuario, pin: '', activa: v.activa })}>✏️ Editar / nuevo PIN</button> },
        ]} />
      </Seccion>
    </>
  )
}
