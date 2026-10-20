import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Campo, Tabla, Aviso } from '../ui.jsx'
import LineasEditor, { lineasParaRpc, SociosEditor, sociosParaRpc, sociosIniciales } from './LineasEditor.jsx'
import { hoy, usd, num } from '../lib.js'

export default function Compras() {
  const { recargarPerfumes, socios } = useApp()
  const ped = useQuery(() => supabase.from('pedidos_v').select('*').order('fecha', { ascending: false }).order('codigo', { ascending: false }), [])
  const det = useQuery(() => supabase.from('compras_v').select('*').order('pedido_codigo', { ascending: false }).order('id'), [])
  const siguiente = 'P-' + String(ped.data.length + 1).padStart(3, '0')
  const [f, setF] = useState({ codigo: '', fecha: hoy(), proveedor: '', envio: 0 })
  const [lineas, setLineas] = useState([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
  const [msg, setMsg] = useState({ error: '', ok: '' })

  const mercancia = lineas.reduce((a, l) => a + num(l.unidades) * num(l.costo_unitario), 0)
  const inversion = mercancia + num(f.envio)
  const [sel, setSel] = useState(null)
  const seleccion = sel || sociosIniciales(socios)

  const guardar = async (e) => {
    e.preventDefault()
    const codigo = f.codigo || siguiente
    const { error } = await supabase.rpc('crear_pedido', {
      p_codigo: codigo, p_fecha: f.fecha, p_proveedor: f.proveedor || null, p_envio: num(f.envio),
      p_socios: sociosParaRpc(seleccion, socios, inversion), p_lineas: lineasParaRpc(lineas),
    })
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: `Pedido ${codigo} registrado. El inventario ya se actualizó.` })
    setLineas([{ nombre: '', unidades: 1, costo_unitario: '', precio_detal: '' }])
    setF({ codigo: '', fecha: hoy(), proveedor: '', envio: 0 })
    setSel(null)
    ped.recargar(); det.recargar(); recargarPerfumes()
  }

  return (
    <>
      <Seccion titulo="Registrar compra" ayuda="El envío se reparte en partes iguales entre las unidades. Toca el precio sugerido para usarlo como precio de venta.">
        <form onSubmit={guardar}>
          <div className="form">
            <Campo label="Pedido"><input value={f.codigo} placeholder={siguiente} onChange={(e) => setF({ ...f, codigo: e.target.value })} /></Campo>
            <Campo label="Fecha"><input type="date" value={f.fecha} onChange={(e) => setF({ ...f, fecha: e.target.value })} required /></Campo>
            <Campo label="Proveedor"><input value={f.proveedor} onChange={(e) => setF({ ...f, proveedor: e.target.value })} /></Campo>
            <Campo label="Envío $"><input type="number" step="0.01" min="0" value={f.envio} onChange={(e) => setF({ ...f, envio: e.target.value })} /></Campo>
          </div>
          <LineasEditor lineas={lineas} setLineas={setLineas} envio={f.envio} />
          <SociosEditor sel={seleccion} setSel={setSel} inversion={inversion} />
          <div className="form">
            <div className="resumen">Mercancía {usd(mercancia)} · Envío {usd(f.envio)} · <b>Inversión {usd(inversion)}</b></div>
            <button className="primario" type="submit">Registrar compra</button>
          </div>
        </form>
        <Aviso {...msg} />
      </Seccion>

      <Seccion titulo="Compras por pedido" ayuda="La columna Diferencia compara lo aportado con lo invertido; debe ser $0.00.">
        <Aviso error={ped.error || det.error} />
        <Tabla filas={ped.data} cols={[
          { k: 'codigo', t: 'Pedido' }, { k: 'fecha', t: 'Fecha' }, { k: 'proveedor', t: 'Proveedor' },
          { k: 'unidades', t: 'Unid.', num: true },
          { k: 'mercancia', t: 'Mercancía', num: true, f: (r) => usd(r.mercancia) },
          { k: 'envio', t: 'Envío', num: true, f: (r) => usd(r.envio) },
          { k: 'inversion', t: 'Inversión', num: true, f: (r) => usd(r.inversion) },
          { k: 'aportes', t: 'Aportado', num: true, f: (r) => usd(r.aportes) },
          { k: 'socios', t: 'Socios y % de ganancia' },
          { k: 'diferencia', t: 'Diferencia', num: true, f: (r) => <b className={Math.abs(r.diferencia) > 0.005 ? 'alerta' : ''}>{usd(r.diferencia)}</b> },
        ]} />
        <h3>Detalle de perfumes</h3>
        <Tabla filas={det.data} cols={[
          { k: 'pedido_codigo', t: 'Pedido' }, { k: 'sku', t: 'SKU' }, { k: 'nombre', t: 'Perfume' },
          { k: 'unidades', t: 'Unid.', num: true },
          { k: 'costo_unitario', t: 'Costo', num: true, f: (r) => usd(r.costo_unitario) },
          { k: 'costo_real', t: 'Costo real (con envío)', num: true, f: (r) => usd(r.costo_real) },
        ]} />
      </Seccion>
    </>
  )
}
