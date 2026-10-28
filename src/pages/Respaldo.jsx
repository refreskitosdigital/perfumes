import React, { useState } from 'react'
import { supabase } from '../supabase.js'
import { Seccion, Aviso } from '../ui.jsx'
import { descargarExcel } from '../excel.js'
import { hoy } from '../lib.js'

// [tabla, nombre para mostrar, columnas ('*' = todas)]
// A las vendedoras se les excluyen la clave (hash) y la sal: nunca salen de la base de datos.
export const TABLAS = [
  ['perfumes', 'Perfumes y catálogo'], ['compras', 'Compras'], ['pedidos', 'Pedidos de compra'], ['pedido_socios', 'Socios por pedido'],
  ['ventas', 'Ventas'], ['cobros', 'Cobros'], ['clientes', 'Clientes'], ['gastos', 'Gastos'], ['pagos', 'Pagos'],
  ['prestamos', 'Préstamos'], ['movimientos', 'Movimientos de caja'], ['tasas', 'Tasas'], ['socios', 'Socios'],
  ['agenda_pedidos', 'Agenda de compra'], ['agenda_lineas', 'Agenda de compra · líneas'], ['agenda_socios', 'Agenda de compra · socios'],
  ['pedidos_web', 'Pedidos de la tienda'], ['pedidos_web_items', 'Pedidos de la tienda · líneas'], ['demanda_web', 'Perfumes agendados por clientes'],
  ['vendedoras', 'Vendedoras', 'id,nombre,usuario,activa,creada'], ['pedidos_vendedora', 'Pedidos de vendedoras'], ['pedidos_vendedora_items', 'Pedidos de vendedoras · líneas'],
  ['cobros_vendedora', 'Cobros de vendedoras'], ['tienda_config', 'Ajustes de la tienda'], ['tienda_banners', 'Banners'],
]
const DIAS = 7
export const diasDesdeRespaldo = () => {
  try { const f = localStorage.getItem('respaldo-ultimo'); if (!f) return null; return Math.floor((Date.now() - new Date(f + 'T12:00:00').getTime()) / 86400000) } catch { return null }
}
const marcar = () => { try { localStorage.setItem('respaldo-ultimo', hoy()) } catch { /* sin almacenamiento */ } }

// Trae toda una tabla (de a 1000 filas). Si la tabla no existe todavía, devuelve null.
async function traer(tabla, cols = '*') {
  const filas = []
  for (let desde = 0; ; desde += 1000) {
    const { data, error } = await supabase.from(tabla).select(cols).range(desde, desde + 999)
    if (error) return /does not exist|schema cache|Could not find/.test(error.message) ? null : Promise.reject(new Error(`${tabla}: ${error.message}`))
    filas.push(...data)
    if (data.length < 1000) break
  }
  return filas
}
const plano = (f) => Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v !== null && typeof v === 'object' ? JSON.stringify(v) : v]))

export default function Respaldo() {
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [ocupado, setOcupado] = useState('')
  const dias = diasDesdeRespaldo()

  const correr = (clave, fn) => async () => {
    setOcupado(clave); setMsg({ error: '', ok: '' })
    try { setMsg({ error: '', ok: await fn() }) } catch (e) { setMsg({ error: e.message, ok: '' }) }
    setOcupado('')
  }
  const todo = async () => { const out = {}; for (const [t, , c] of TABLAS) { const f = await traer(t, c); if (f) out[t] = f } return out }

  const completoExcel = correr('excel', async () => {
    const datos = await todo()
    await descargarExcel('respaldo-perfumes', Object.fromEntries(Object.entries(datos).map(([t, f]) => [TABLAS.find((x) => x[0] === t)[1], f.map(plano)])))
    marcar(); return `Respaldo en Excel descargado (${Object.keys(datos).length} hojas).`
  })
  const completoJson = correr('json', async () => {
    const datos = await todo()
    const blob = new Blob([JSON.stringify({ generado: new Date().toISOString(), tablas: datos }, null, 1)], { type: 'application/json' })
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = `respaldo-perfumes-${hoy()}.json`; a.click(); URL.revokeObjectURL(a.href)
    marcar(); return 'Respaldo completo descargado (JSON). Guárdalo en un lugar seguro: tiene todos tus datos.'
  })
  const una = (t, nombre, c) => correr(t, async () => {
    const f = await traer(t, c)
    if (!f) throw new Error('Esa tabla todavía no existe en tu base de datos.')
    await descargarExcel(t, { [nombre]: f.map(plano) }); return `${nombre}: ${f.length} filas descargadas.`
  })

  return (
    <>
      <Seccion titulo="Respaldo completo" ayuda="Baja todos los datos del negocio a tu computador. Hazlo una vez por semana y guarda el archivo en Drive o en tu correo.">
        <div className={'aviso ' + (dias == null || dias >= DIAS ? 'error' : 'ok')}>
          {dias == null ? 'Aún no has hecho ningún respaldo desde este navegador.' : dias >= DIAS ? `Tu último respaldo fue hace ${dias} días. Toca hacer uno.` : `Último respaldo: hace ${dias === 0 ? 'unas horas' : dias + (dias === 1 ? ' día' : ' días')}.`}
        </div>
        <div className="acciones-fila">
          <button className="primario" onClick={completoExcel} disabled={!!ocupado}>{ocupado === 'excel' ? 'Preparando…' : 'Descargar todo en Excel'}</button>
          <button onClick={completoJson} disabled={!!ocupado}>{ocupado === 'json' ? 'Preparando…' : 'Descargar respaldo completo (JSON)'}</button>
        </div>
        <Aviso {...msg} />
        <p className="ayuda">El Excel trae una hoja por tabla. El JSON es el respaldo «de seguridad»: sirve para restaurar los datos si algún día hace falta. Las claves (PIN) de las vendedoras nunca se descargan.</p>
      </Seccion>
      <Seccion titulo="Descargar una tabla en Excel">
        <div className="lista-descargas">
          {TABLAS.map(([t, n, c]) => <button key={t} onClick={una(t, n, c)} disabled={!!ocupado}>{ocupado === t ? 'Descargando…' : n}</button>)}
        </div>
      </Seccion>
    </>
  )
}
