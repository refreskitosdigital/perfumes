import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Aviso } from '../ui.jsx'
import LineasEditor, { lineasParaRpc, SociosEditor, sociosParaRpc, sociosIniciales } from './LineasEditor.jsx'
import { usd, num } from '../lib.js'

export default function Agenda() {
  const { recargarPerfumes, socios } = useApp()
  const ped = useQuery(() => supabase.from('agenda_pedidos').select('*').order('registrado').order('codigo'), [])
  const lin = useQuery(() => supabase.from('agenda_lineas').select('*').order('id'), [])
  const ags = useQuery(() => supabase.from('agenda_socios').select('*'), [])
  const [sel, setSel] = useState(null)
  const [f, setF] = useState({ codigo: '', fecha_prevista: '', proveedor: '', envio: 0 })
  const [lineas, setLineas] = useState([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const siguiente = 'A-' + String(ped.data.length + 1).padStart(3, '0')

  const guardar = async (e) => {
    e.preventDefault()
    const codigo = f.codigo || siguiente
    const items = lineasParaRpc(lineas)
    const merc = items.reduce((a, l) => a + l.unidades * l.costo_unitario, 0)
    const reparto = sociosParaRpc(sel || sociosIniciales(socios), socios, merc + num(f.envio))
    if (!reparto.length) return setMsg({ error: 'Elige al menos un socio.', ok: '' })
    if (!items.length) return setMsg({ error: 'Agrega al menos un perfume.', ok: '' })
    const { error } = await supabase.from('agenda_pedidos').insert({
      codigo, fecha_prevista: f.fecha_prevista || null, proveedor: f.proveedor || null, envio: num(f.envio),
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    const { error: e2 } = await supabase.from('agenda_lineas').insert(items.map((l) => ({ codigo, ...l })))
    if (e2) return setMsg({ error: e2.message, ok: '' })
    const { error: e3 } = await supabase.from('agenda_socios').insert(reparto.map((r) => ({ codigo, socio: r.socio, aporte: r.aporte })))
    if (e3) return setMsg({ error: e3.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${codigo} agendado. No cuenta en inventario ni compras hasta registrarlo.` })
    setF({ codigo: '', fecha_prevista: '', proveedor: '', envio: 0 })
    setLineas([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
    setSel(null)
    ped.recargar(); lin.recargar(); ags.recargar()
  }

  const registrar = async (p) => {
    const items = lin.data.filter((l) => l.codigo === p.codigo)
    const unid = items.reduce((a, l) => a + l.unidades, 0)
    const merc = items.reduce((a, l) => a + l.unidades * l.costo_unitario, 0)
    const ok = window.confirm(`Registrar ${p.codigo}\n${items.length} perfumes, ${unid} unidades\nMercancía ${usd(merc)} + envío ${usd(p.envio)} = ${usd(merc + num(p.envio))}\n\nSe registra con la fecha de hoy. ¿Continuar?`)
    if (!ok) return
    const { error } = await supabase.rpc('registrar_pedido', { p_codigo: p.codigo })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${p.codigo} registrado. Ya aparece en Compras e Inventario.` })
    ped.recargar(); recargarPerfumes()
  }

  const borrar = async (p) => {
    if (!window.confirm(`¿Eliminar ${p.codigo} de la Agenda?`)) return
    await supabase.from('agenda_pedidos').delete().eq('codigo', p.codigo)
    ped.recargar(); lin.recargar()
  }

  return (
    <>
      <Seccion titulo="Agendar pedido" ayuda="Pedidos próximos a hacer. No cuentan en inventario ni en compras hasta que pulses Registrar.">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Código"><input value={f.codigo} placeholder={siguiente} onChange={(e) => setF({ ...f, codigo: e.target.value })} /></Campo>
            <Campo label="Fecha prevista"><input type="date" value={f.fecha_prevista} onChange={(e) => setF({ ...f, fecha_prevista: e.target.value })} /></Campo>
            <Campo label="Proveedor"><input value={f.proveedor} onChange={(e) => setF({ ...f, proveedor: e.target.value })} /></Campo>
            <Campo label="Envío $"><input type="number" step="0.01" min="0" value={f.envio} onChange={(e) => setF({ ...f, envio: e.target.value })} /></Campo>
          </div>
          <LineasEditor lineas={lineas} setLineas={setLineas} envio={f.envio} />
          <SociosEditor sel={sel || sociosIniciales(socios)} setSel={setSel} inversion={lineas.reduce((a, l) => a + num(l.unidades) * num(l.costo_unitario), 0) + num(f.envio)} />
          <button className="primario" type="submit">Agendar</button>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Pedidos agendados">
        <Aviso error={ped.error || lin.error || ags.error} />
        {!ped.data.length && <p className="vacio">No hay pedidos agendados.</p>}
        {ped.data.map((p) => {
          const items = lin.data.filter((l) => l.codigo === p.codigo)
          const merc = items.reduce((a, l) => a + l.unidades * l.costo_unitario, 0)
          return (
            <article key={p.codigo} className={'pedido ' + (p.registrado ? 'hecho' : '')}>
              <header>
                <div><b>{p.codigo}</b> · {p.proveedor || 'sin proveedor'} · {p.fecha_prevista || 'sin fecha'} · Socios: {ags.data.filter((x) => x.codigo === p.codigo).map((x) => x.socio).join(', ') || '—'}</div>
                <div>Mercancía {usd(merc)} + envío {usd(p.envio)} = <b>{usd(merc + num(p.envio))}</b></div>
                {p.registrado
                  ? <span className="etiqueta">Registrado</span>
                  : <span><button className="primario" onClick={() => registrar(p)}>Registrar</button> <button onClick={() => borrar(p)}>Eliminar</button></span>}
              </header>
              <ul>{items.map((l) => <li key={l.id}>{l.nombre} · {l.unidades} u · costo {usd(l.costo_unitario)}{l.precio_detal ? ` · venta ${usd(l.precio_detal)}` : ''}</li>)}</ul>
            </article>
          )
        })}
      </Seccion>
    </>
  )
}
