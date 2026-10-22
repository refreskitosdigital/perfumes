import { reducirImagen } from '../imagen.js'
import React, { useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { useApp } from '../App.jsx'
import { Seccion, Aviso, Guia, Insignia } from '../ui.jsx'
import { usd, pct, precioSugerido, num, normNombre, hoy } from '../lib.js'
import { crearListaPdf } from '../pdf.js'

const fechaLarga = () => new Date().toLocaleDateString('es-VE', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'America/Caracas' })

export default function Inventario() {
  const { config, recargarPerfumes, perfumes } = useApp()
  const meta = useMemo(() => Object.fromEntries(perfumes.data.map((p) => [p.id, p])), [perfumes.data])
  const [subiendo, setSubiendo] = useState(null)
  const inv = useQuery(() => supabase.from('inventario_v').select('*').order('sku'), [])
  const compras = useQuery(() => supabase.from('compras_v').select('id,pedido_codigo,fecha,perfume_id,unidades,costo_unitario,costo_real').order('fecha', { ascending: false }).order('id'), [])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [buscar, setBuscar] = useState('')
  const [soloStock, setSoloStock] = useState(false)
  const [abierto, setAbierto] = useState(null)

  const recargar = () => { inv.recargar(); compras.recargar(); recargarPerfumes() }
  const ok = (texto) => setMsg({ error: '', ok: texto })
  const fallo = (e) => setMsg({ error: e.message || String(e), ok: '' })

  const editarPrecio = async (id, campo, valor) => {
    const v = valor === '' ? null : Number(valor)
    const { error } = await supabase.from('perfumes').update({ [campo]: v }).eq('id', id)
    if (error) return fallo(error)
    setMsg({ error: '', ok: '' }); recargar()
  }
  const celda = (campo) => (r) => (
    <input className="mini" type="number" step="0.5" min="0" defaultValue={r[campo] ?? ''} onBlur={(e) => {
      if (String(r[campo] ?? '') !== e.target.value) editarPrecio(r.id, campo, e.target.value)
    }} />
  )

  const sinPrecio = inv.data.filter((r) => r.precio_detal == null && num(r.costo) > 0)
  const ponerSugeridos = async () => {
    if (!window.confirm(`Se le pondrá el precio sugerido (costo + ${pct(config.ganancia_objetivo)}) a ${sinPrecio.length} perfumes que no tienen precio al detal. Luego puedes cambiar cada uno. ¿Continuar?`)) return
    const res = await Promise.all(sinPrecio.map((r) => supabase.from('perfumes').update({
      precio_detal: precioSugerido(r.costo, num(config.ganancia_objetivo), config.base_ganancia, num(config.redondeo)),
    }).eq('id', r.id)))
    const fallo_ = res.find((x) => x.error)
    if (fallo_) return fallo(fallo_.error)
    ok(`Listo: ${sinPrecio.length} perfumes ahora tienen precio sugerido. Revísalos y ajústalos a tu gusto.`); recargar()
  }

  const guardarCosto = async (c, valor) => {
    if (valor === '' || num(valor) < 0 || String(c.costo_unitario) === String(valor)) return
    const { error } = await supabase.from('compras').update({ costo_unitario: num(valor) }).eq('id', c.id)
    if (error) return fallo(error)
    ok(`Costo del pedido ${c.pedido_codigo} actualizado a ${usd(valor)}. Las ganancias se recalcularon.`); recargar()
  }
  // Cada perfume lleva 2 fotos: foto_url (principal) y foto2_url (aparece al pasar el cursor en la tienda)
  const subirFoto = async (r, archivo, campo = 'foto_url') => {
    if (!archivo) return
    setSubiendo(r.id + campo)
    try {
      const blob = await reducirImagen(archivo, 1100)
      const ruta = `${r.id}-${campo === 'foto2_url' ? 'b' : 'a'}-${Date.now()}.jpg`
      const up = await supabase.storage.from('perfumes').upload(ruta, blob, { contentType: 'image/jpeg', upsert: true })
      if (up.error) throw up.error
      const { data } = supabase.storage.from('perfumes').getPublicUrl(ruta)
      const { error } = await supabase.from('perfumes').update({ [campo]: data.publicUrl }).eq('id', r.id)
      if (error) throw (/foto2_url/.test(error.message) ? new Error('Falta ejecutar migracion_v5.sql en Supabase.') : error)
      ok('Foto guardada. Ya se ve en la tienda.'); recargar()
    } catch (e) { fallo(e) } finally { setSubiendo(null) }
  }
  const quitarFoto = async (r, campo = 'foto_url') => {
    const { error } = await supabase.from('perfumes').update({ [campo]: null }).eq('id', r.id)
    if (error) return fallo(error); ok('Foto quitada.'); recargar()
  }
  const visibleTienda = async (r, v) => {
    const { error } = await supabase.from('perfumes').update({ visible_tienda: v }).eq('id', r.id)
    if (error) return fallo(error); ok(v ? 'Ahora se muestra en la tienda.' : 'Ya no se muestra en la tienda.'); recargar()
  }

  const guardarNombre = async (r, valor) => {
    const nombre = valor.trim()
    if (!nombre || nombre === r.nombre) return
    const { error } = await supabase.from('perfumes').update({ nombre }).eq('id', r.id)
    if (error) return fallo(error.code === '23505' ? 'Ya existe un perfume con ese nombre.' : error)
    ok('Nombre actualizado.'); recargar()
  }

  const visibles = useMemo(() => inv.data.filter((r) =>
    (!soloStock || r.stock > 0) && (!buscar || normNombre(r.nombre).includes(normNombre(buscar)) || normNombre(r.sku).includes(normNombre(buscar)))
  ), [inv.data, soloStock, buscar])

  // Listas para clientes: solo perfumes disponibles (stock > 0), nombre y precio
  const lista = async (tipo) => {
    const mayor = tipo === 'mayor'
    const disponibles = inv.data.filter((r) => r.stock > 0)
    const conPrecio = disponibles
      .map((r) => ({ nombre: r.nombre, valor: mayor ? (r.precio_mayor ?? r.precio_detal) : r.precio_detal }))
      .filter((r) => r.valor != null && num(r.valor) > 0)
      .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
    const sinPrecio = disponibles.length - conPrecio.length
    if (!conPrecio.length) return setMsg({ error: `No hay perfumes disponibles con precio ${mayor ? 'al mayor' : 'al detal'}. Pon los precios en la tabla.`, ok: '' })
    try {
      await crearListaPdf({
        titulo: mayor ? 'Lista de precios al mayor' : 'Catálogo de perfumes',
        subtitulo: (mayor ? `Precios por unidad comprando desde ${config.umbral_mayor} perfumes · ` : 'Precios al detal · ') + fechaLarga(),
        filas: conPrecio.map((r) => ({ nombre: r.nombre, precio: usd(r.valor) })),
        nota: 'Precios en dólares · sujetos a cambio y a disponibilidad.',
        archivo: `lista-${mayor ? 'mayor' : 'detal'}-${hoy()}.pdf`,
      })
      ok(`PDF descargado con ${conPrecio.length} perfumes disponibles.` + (sinPrecio ? ` ${sinPrecio} más no salieron porque no tienen precio ${mayor ? 'al mayor ni al detal' : 'al detal'}.` : ''))
    } catch (e) { fallo(e) }
  }

  const filaDetalle = (r) => {
    const cs = compras.data.filter((c) => c.perfume_id === r.id)
    return (
      <tr key={'d' + r.id}><td colSpan={11} className="detalle-costos">
        <b>Foto y precios (lo que ve el cliente en la tienda)</b>
        <div className="foto-panel">
          {[['foto_url', 'Foto 1 · principal'], ['foto2_url', 'Foto 2 · al pasar el cursor']].map(([campo, titulo]) => (
            <div key={campo} className="foto-slot">
              <small>{titulo}</small>
              {meta[r.id]?.[campo] ? <img src={meta[r.id][campo]} alt={`${r.nombre}, ${titulo}`} /> : <div className="sin-foto">Sin foto</div>}
              <div className="atajos">
                <label className="boton-link" style={{ cursor: 'pointer' }}>
                  {subiendo === r.id + campo ? 'Subiendo…' : meta[r.id]?.[campo] ? '📷 Cambiar' : '📷 Subir'}
                  <input type="file" accept="image/*" hidden disabled={subiendo === r.id + campo} onChange={(e) => { subirFoto(r, e.target.files?.[0], campo); e.target.value = '' }} />
                </label>
                {meta[r.id]?.[campo] && <button onClick={() => quitarFoto(r, campo)}>Quitar</button>}
              </div>
            </div>
          ))}
        </div>
        <div className="form">
          <label className="campo"><span>Nombre del perfume</span>
            <input defaultValue={r.nombre} onBlur={(e) => guardarNombre(r, e.target.value)} /></label>
          <label className="campo"><span>Precio al detal $</span>
            <input type="number" step="0.5" min="0" defaultValue={r.precio_detal ?? ''} onBlur={(e) => { if (String(r.precio_detal ?? '') !== e.target.value) editarPrecio(r.id, 'precio_detal', e.target.value) }} /></label>
          <label className="campo"><span>Precio al mayor $</span>
            <input type="number" step="0.5" min="0" defaultValue={r.precio_mayor ?? ''} onBlur={(e) => { if (String(r.precio_mayor ?? '') !== e.target.value) editarPrecio(r.id, 'precio_mayor', e.target.value) }} /></label>
          <label className="check"><input type="checkbox" checked={meta[r.id]?.visible_tienda !== false} onChange={(e) => visibleTienda(r, e.target.checked)} /> Mostrar en la tienda online</label>
        </div>
        <b>Lo que costó en cada compra</b>
        <p className="ayuda">Si te hicieron una rebaja, cambia el costo de esa compra. Se guarda al salir de la casilla y las ganancias se recalculan solas (incluidas las ventas ya hechas de ese pedido).</p>
        {!cs.length ? <p className="vacio">Este perfume todavía no tiene compras.</p> : (
          <div className="tabla-wrap"><table>
            <thead><tr><th>Pedido</th><th>Fecha</th><th className="num">Unidades</th><th className="num">Costo por unidad $</th><th className="num">Costo real (con envío)</th></tr></thead>
            <tbody>{cs.map((c) => (
              <tr key={c.id}>
                <td>{c.pedido_codigo}</td><td>{String(c.fecha).slice(0, 10)}</td><td className="num">{c.unidades}</td>
                <td className="num"><input className="mini" type="number" step="0.01" min="0" defaultValue={c.costo_unitario}
                  onBlur={(e) => guardarCosto(c, e.target.value)} /></td>
                <td className="num">{usd(c.costo_real)}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </td></tr>
    )
  }

  return (
    <>
      <Guia>Aquí ves qué perfumes tienes y a cuánto los vendes. Toca <b>✏️ Editar</b> en cualquier perfume para corregir lo que te costó (por ejemplo, si te hicieron una rebaja), <b>subir su foto</b> para la tienda online y cambiar sus precios. Abajo puedes descargar las <b>listas en PDF para tus clientes</b>: solo salen los perfumes que hay en stock, con su nombre y precio.</Guia>
      <Aviso {...msg} error={msg.error || inv.error || compras.error} />

      <Seccion titulo="Listas para tus clientes (PDF)" ayuda="No incluyen costos, ganancias ni cantidades: solo el nombre y el precio de lo que tienes disponible.">
        <div className="atajos">
          <button className="primario" onClick={() => lista('detal')}>📄 Descargar lista al detal</button>
          <button className="primario" onClick={() => lista('mayor')}>📄 Descargar lista al mayor</button>
          <span className="ayuda">Al mayor se usa el precio “Mayor $”; si un perfume no lo tiene, sale con el precio al detal.</span>
        </div>
      </Seccion>

      <Seccion titulo={`Perfumes (${visibles.length})`} ayuda={`Los perfumes y su SKU se crean solos al registrar compras. Edita aquí los precios de venta. El precio al mayor aplica desde ${config.umbral_mayor} unidades.`}
        acciones={
          <div className="filtros">
            <input className="buscador" placeholder="🔍 Buscar perfume o SKU" value={buscar} onChange={(e) => setBuscar(e.target.value)} />
            <label className="check"><input type="checkbox" checked={soloStock} onChange={(e) => setSoloStock(e.target.checked)} /> Solo con stock</label>
          </div>
        }>
        {!visibles.length ? <p className="vacio">No hay perfumes que mostrar.</p> : (
          <div className="tabla-wrap">
            <table>
              <thead><tr>
                <th>SKU</th><th>Perfume</th><th className="num">Stock</th><th className="num">Vendidos</th>
                <th className="num">Costo real</th><th className="num">Sugerido {pct(config.ganancia_objetivo)}</th>
                <th className="num">Detal $</th><th className="num">Mayor $</th><th className="num">Rent. detal</th><th className="num">Ganancia</th><th />
              </tr></thead>
              <tbody>
                {visibles.map((r) => (
                  <React.Fragment key={r.id}>
                    <tr className={abierto === r.id ? 'fila-activa' : ''}>
                      <td>{r.sku}</td><td>{meta[r.id]?.foto_url && <img className="miniatura" src={meta[r.id].foto_url} alt="" />}<b>{r.nombre}</b></td>
                      <td className="num"><b className={r.stock <= 1 ? 'alerta' : ''}>{r.stock < 0 ? `${r.stock} (por comprar)` : r.stock}</b></td>
                      <td className="num">{r.vendidos}</td>
                      <td className="num">{usd(r.costo)}</td>
                      <td className="num">{usd(precioSugerido(r.costo, num(config.ganancia_objetivo), config.base_ganancia, num(config.redondeo)))}</td>
                      <td className="num">{celda('precio_detal')(r)}</td>
                      <td className="num">{celda('precio_mayor')(r)}</td>
                      <td className="num">{pct(r.margen_detal)}</td>
                      <td className="num">{usd(r.ganancia)}</td>
                      <td><button onClick={() => setAbierto(abierto === r.id ? null : r.id)}>✏️ Editar</button></td>
                    </tr>
                    {abierto === r.id && filaDetalle(r)}
                  </React.Fragment>
                ))}
              </tbody>
            </table>
          </div>
        )}
        {inv.data.some((r) => r.stock > 0 && r.precio_detal == null) && (
          <div className="guia"><span aria-hidden="true">⚠️</span><div>
            Hay perfumes en stock <b>sin precio al detal</b>; no saldrán en la lista en PDF y en la tienda online solo se podrán <b>agendar</b> (salen como "Precio por confirmar") hasta que les pongas precio.{' '}
            {sinPrecio.length > 0 && <button onClick={ponerSugeridos}>💡 Poner el precio sugerido a los {sinPrecio.length} que no tienen</button>}
          </div></div>
        )}
      </Seccion>
    </>
  )
}
