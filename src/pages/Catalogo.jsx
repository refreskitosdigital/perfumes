import React, { useMemo, useState } from 'react'
import { supabase } from '../supabase.js'
import { useQuery } from '../hooks.js'
import { Seccion, Campo, Aviso, Guia, Insignia } from '../ui.jsx'
import { usd, num, pct } from '../lib.js'
import { reducirImagen } from '../imagen.js'

const vacioNuevo = { nombre: '', marca: '', genero: '', notas: '', tips_venta: '', descripcion: '', precio_detal: '', precio_mayor: '', precio_consigna: '', existencia_manual: '' }
const aNum = (v) => (v === '' || v == null ? null : num(v))
const aTexto = (v) => (v == null ? '' : String(v))

// Revisa que los 3 precios no choquen: costo < consignación ≤ mayor ≤ detal
export function avisosPrecios({ costo, consigna, mayor, detal }) {
  const a = []
  if (consigna != null && costo > 0 && consigna <= costo) a.push(`La consignación (${usd(consigna)}) debe ser mayor que el costo (${usd(costo)}) o no ganas nada.`)
  if (consigna != null && mayor != null && consigna > mayor) a.push(`La consignación (${usd(consigna)}) es más alta que el precio al mayor (${usd(mayor)}): una vendedora te pagaría más de lo que paga un cliente al mayor.`)
  if (mayor != null && detal != null && mayor > detal) a.push(`El precio al mayor (${usd(mayor)}) es más alto que el de la tienda (${usd(detal)}).`)
  if (consigna != null && detal != null && consigna > detal) a.push(`La consignación (${usd(consigna)}) es más alta que el precio de la tienda (${usd(detal)}): a la vendedora no le quedaría ganancia.`)
  return a
}

export default function Catalogo() {
  const lista = useQuery(() => supabase.from('perfumes').select('*').order('nombre'), [])
  const inv = useQuery(() => supabase.from('inventario_v').select('id,stock,comprados,costo'), [])
  const [buscar, setBuscar] = useState('')
  const [filtro, setFiltro] = useState('todos')
  const [abierto, setAbierto] = useState(null)
  const [form, setForm] = useState(null)
  const [nuevo, setNuevo] = useState(null)
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [subiendo, setSubiendo] = useState(null)

  const invPor = useMemo(() => Object.fromEntries(inv.data.map((r) => [r.id, r])), [inv.data])
  const ok = (m) => setMsg({ error: '', ok: m })
  const fallo = (e) => setMsg({ error: e.message || String(e), ok: '' })
  const recargar = () => { lista.recargar(); inv.recargar() }
  const enInventario = (p) => num(invPor[p.id]?.comprados) > 0
  const existencia = (p) => (enInventario(p) ? num(invPor[p.id]?.stock) : num(p.existencia_manual))

  const filas = lista.data.filter((p) => {
    if (buscar && !p.nombre.toLowerCase().includes(buscar.toLowerCase())) return false
    if (filtro === 'tienda') return p.visible_tienda
    if (filtro === 'solo') return !enInventario(p)
    if (filtro === 'sinfoto') return !p.foto_url
    if (filtro === 'sinprecio') return p.precio_detal == null || p.precio_consigna == null
    if (filtro === 'sinmarca') return !p.marca || !p.genero
    return true
  })

  const abrir = (p) => {
    if (abierto === p.id) return setAbierto(null)
    setAbierto(p.id); setMsg({ error: '', ok: '' })
    setForm({
      nombre: p.nombre, marca: aTexto(p.marca), genero: p.genero || '', notas: aTexto(p.notas), tips_venta: aTexto(p.tips_venta), descripcion: aTexto(p.descripcion), precio_detal: aTexto(p.precio_detal), precio_mayor: aTexto(p.precio_mayor),
      precio_consigna: aTexto(p.precio_consigna), existencia_manual: aTexto(p.existencia_manual),
      visible_tienda: p.visible_tienda, visible_vendedoras: p.visible_vendedoras,
    })
  }

  const guardar = async (p) => {
    if (!form.nombre.trim()) return fallo(new Error('El perfume necesita un nombre.'))
    const pr = { costo: num(invPor[p.id]?.costo), consigna: aNum(form.precio_consigna), mayor: aNum(form.precio_mayor), detal: aNum(form.precio_detal) }
    const av = avisosPrecios(pr)
    if (av.length && !window.confirm('Los precios no cuadran:\n\n• ' + av.join('\n• ') + '\n\n¿Guardar igual?')) return
    const { error } = await supabase.from('perfumes').update({
      nombre: form.nombre.trim(), descripcion: form.descripcion.trim() || null,
      marca: form.marca.trim() || null, genero: form.genero || null, notas: form.notas.trim() || null, tips_venta: form.tips_venta.trim() || null,
      precio_detal: pr.detal, precio_mayor: pr.mayor, precio_consigna: pr.consigna,
      existencia_manual: enInventario(p) ? p.existencia_manual : (aNum(form.existencia_manual) == null ? null : Math.round(aNum(form.existencia_manual))),
      visible_tienda: form.visible_tienda, visible_vendedoras: form.visible_vendedoras,
    }).eq('id', p.id)
    if (error) return fallo(/existencia_manual|descripcion|precio_consigna|visible_vendedoras/.test(error.message) ? new Error('Falta ejecutar migracion_v9.sql en Supabase.') : /marca|genero|notas|tips_venta/.test(error.message) ? new Error('Falta ejecutar migracion_v10.sql en Supabase.') : error)
    ok('Perfume guardado. Ya se actualizó en la tienda y para las vendedoras.'); recargar()
  }

  const subirFoto = async (p, archivo, campo) => {
    if (!archivo) return
    setSubiendo(p.id + campo)
    try {
      const blob = await reducirImagen(archivo, 1100)
      const ruta = `${p.id}-${campo === 'foto2_url' ? 'b' : 'a'}-${Date.now()}.jpg`
      const up = await supabase.storage.from('perfumes').upload(ruta, blob, { contentType: 'image/jpeg', upsert: true })
      if (up.error) throw up.error
      const { data } = supabase.storage.from('perfumes').getPublicUrl(ruta)
      const { error } = await supabase.from('perfumes').update({ [campo]: data.publicUrl }).eq('id', p.id)
      if (error) throw error
      ok('Foto guardada.'); recargar()
    } catch (e) { fallo(e) } finally { setSubiendo(null) }
  }
  const quitarFoto = async (p, campo) => {
    const { error } = await supabase.from('perfumes').update({ [campo]: null }).eq('id', p.id)
    if (error) return fallo(error); ok('Foto quitada.'); recargar()
  }

  const crear = async (e) => {
    e.preventDefault()
    const pr = { costo: 0, consigna: aNum(nuevo.precio_consigna), mayor: aNum(nuevo.precio_mayor), detal: aNum(nuevo.precio_detal) }
    const av = avisosPrecios(pr)
    if (av.length && !window.confirm('Los precios no cuadran:\n\n• ' + av.join('\n• ') + '\n\n¿Guardar igual?')) return
    const { data, error } = await supabase.from('perfumes').insert({
      nombre: nuevo.nombre.trim(), descripcion: nuevo.descripcion.trim() || null,
      marca: nuevo.marca.trim() || null, genero: nuevo.genero || null, notas: nuevo.notas.trim() || null, tips_venta: nuevo.tips_venta.trim() || null,
      precio_detal: pr.detal, precio_mayor: pr.mayor, precio_consigna: pr.consigna,
      existencia_manual: aNum(nuevo.existencia_manual) == null ? 0 : Math.round(aNum(nuevo.existencia_manual)),
    }).select('id').single()
    if (error) return fallo(/perfumes_nombre_uq|duplicate/.test(error.message) ? new Error('Ya existe un perfume con ese nombre.') : /existencia_manual|descripcion|precio_consigna/.test(error.message) ? new Error('Falta ejecutar migracion_v9.sql en Supabase.') : /marca|genero|notas|tips_venta/.test(error.message) ? new Error('Falta ejecutar migracion_v10.sql en Supabase.') : error)
    ok(`"${nuevo.nombre.trim()}" agregado al catálogo. Sube sus fotos abriéndolo abajo.`)
    setNuevo(null); recargar()
    if (data?.id) setTimeout(() => { setAbierto(null) }, 0)
  }

  const fPrecios = form && abierto ? (() => {
    const p = lista.data.find((x) => x.id === abierto)
    return p ? avisosPrecios({ costo: num(invPor[p.id]?.costo), consigna: aNum(form.precio_consigna), mayor: aNum(form.precio_mayor), detal: aNum(form.precio_detal) }) : []
  })() : []

  return (
    <>
      <Guia>
        El <b>catálogo</b> es lo que se publica en la tienda y lo que ven las vendedoras. Un perfume puede estar aquí <b>sin que lo tengas en inventario</b>: la gente lo agenda y así sabes qué comprar.
        Cada perfume tiene <b>3 precios separados</b>: <b>Tienda</b> (público), <b>Mayor</b> (público, desde 12 perfumes) y <b>Consignación</b> (lo que te debe una vendedora). La tienda nunca ve la consignación y las vendedoras nunca ven el mayor ni tu costo.
      </Guia>
      <Aviso {...msg} />

      <Seccion titulo="Perfumes del catálogo" ayuda={`${lista.data.length} perfumes · ${lista.data.filter((p) => p.visible_tienda).length} en la tienda`}
        acciones={<button className="primario" onClick={() => setNuevo(nuevo ? null : { ...vacioNuevo })}>{nuevo ? 'Cerrar' : '➕ Nuevo perfume'}</button>}>
        {nuevo && (
          <form onSubmit={crear} className="cat-nuevo">
            <div className="form">
              <Campo label="Nombre del perfume"><input value={nuevo.nombre} onChange={(e) => setNuevo({ ...nuevo, nombre: e.target.value })} required /></Campo>
              <Campo label="Precio tienda $"><input type="number" step="0.01" min="0" inputMode="decimal" value={nuevo.precio_detal} onChange={(e) => setNuevo({ ...nuevo, precio_detal: e.target.value })} /></Campo>
              <Campo label="Precio mayor $"><input type="number" step="0.01" min="0" inputMode="decimal" value={nuevo.precio_mayor} onChange={(e) => setNuevo({ ...nuevo, precio_mayor: e.target.value })} /></Campo>
              <Campo label="Consignación $"><input type="number" step="0.01" min="0" inputMode="decimal" value={nuevo.precio_consigna} onChange={(e) => setNuevo({ ...nuevo, precio_consigna: e.target.value })} /></Campo>
              <Campo label="¿Cuántos tienes?" ayuda="Si no lo tienes, deja 0"><input type="number" min="0" inputMode="numeric" value={nuevo.existencia_manual} onChange={(e) => setNuevo({ ...nuevo, existencia_manual: e.target.value })} /></Campo>
            </div>
<div className="form">
              <Campo label="Marca"><input list="cat-marcas" value={nuevo.marca} onChange={(e) => setNuevo({ ...nuevo, marca: e.target.value })} placeholder="Ej.: Lattafa" /></Campo>
              <Campo label="Género">
                <select value={nuevo.genero} onChange={(e) => setNuevo({ ...nuevo, genero: e.target.value })}>
                  <option value="">Sin definir</option><option value="mujer">Mujer</option><option value="hombre">Hombre</option><option value="unisex">Unisex</option>
                </select>
              </Campo>
            </div>
            <Campo label="Descripción (se ve en la tienda y en el link de vendedoras)"><textarea rows="3" value={nuevo.descripcion} onChange={(e) => setNuevo({ ...nuevo, descripcion: e.target.value })} placeholder="Para quién es, cuándo usarlo, duración…" /></Campo>
            <Campo label="Notas y tonos (tienda y vendedoras)"><input value={nuevo.notas} onChange={(e) => setNuevo({ ...nuevo, notas: e.target.value })} placeholder="Salida: bergamota · Corazón: rosa · Fondo: ámbar" /></Campo>
            <Campo label="Tips para vender (solo las vendedoras lo ven)"><textarea rows="2" value={nuevo.tips_venta} onChange={(e) => setNuevo({ ...nuevo, tips_venta: e.target.value })} placeholder="Ej.: ideal para regalo; huele parecido a …" /></Campo>
            <button className="primario" type="submit">Agregar al catálogo</button>
          </form>
        )}

        <datalist id="cat-marcas">{[...new Set(lista.data.map((p) => p.marca).filter(Boolean))].sort().map((m) => <option key={m} value={m} />)}</datalist>
        <div className="form cat-filtros">
          <Campo label="Buscar"><input value={buscar} onChange={(e) => setBuscar(e.target.value)} placeholder="Nombre del perfume" /></Campo>
          <Campo label="Mostrar">
            <select value={filtro} onChange={(e) => setFiltro(e.target.value)}>
              <option value="todos">Todos</option><option value="tienda">Los que están en la tienda</option>
              <option value="solo">Solo catálogo (sin inventario)</option><option value="sinfoto">Sin foto</option>
              <option value="sinprecio">Falta algún precio</option><option value="sinmarca">Sin marca o sin género</option>
            </select>
          </Campo>
        </div>
        <Aviso error={lista.error || inv.error} />

        <div className="cat-lista">
          {filas.map((p) => {
            const costo = num(invPor[p.id]?.costo)
            return (
              <article key={p.id} className={'cat-item' + (abierto === p.id ? ' abierto' : '')}>
                <div className="cat-fila">
                  <div className="cat-mini">{p.foto_url ? <img src={p.foto_url} alt="" /> : <span aria-hidden="true">🧴</span>}</div>
                  <div className="cat-datos">
                    <b>{p.nombre}</b>
                    <div className="cat-badges">
                      {enInventario(p) ? <Insignia tono="ok">En inventario · {existencia(p)}</Insignia> : <Insignia tono="warn">Solo catálogo · {existencia(p)} {existencia(p) === 1 ? 'unidad' : 'unidades'}</Insignia>}
                      {!p.visible_tienda && <Insignia>Oculto en tienda</Insignia>}
                      {!p.foto_url && <Insignia>Sin foto</Insignia>}
                    </div>
                  </div>
                  <div className="cat-precios">
                    <span title="Precio tienda">🛒 {p.precio_detal != null ? usd(p.precio_detal) : '—'}</span>
                    <span title="Precio al mayor">📦 {p.precio_mayor != null ? usd(p.precio_mayor) : '—'}</span>
                    <span title="Consignación (vendedoras)">🤝 {p.precio_consigna != null ? usd(p.precio_consigna) : '—'}</span>
                  </div>
                  <button onClick={() => abrir(p)}>{abierto === p.id ? 'Cerrar' : '✏️ Editar'}</button>
                </div>

                {abierto === p.id && form && (
                  <div className="cat-editor">
                    <div className="foto-panel">
                      {[['foto_url', 'Foto 1 · principal'], ['foto2_url', 'Foto 2 · al pasar el cursor']].map(([campo, titulo]) => (
                        <div key={campo} className="foto-slot">
                          <small>{titulo}</small>
                          {p[campo] ? <img src={p[campo]} alt={`${p.nombre}, ${titulo}`} /> : <div className="sin-foto">Sin foto</div>}
                          <div className="atajos">
                            <label className="boton-link" style={{ cursor: 'pointer' }}>
                              {subiendo === p.id + campo ? 'Subiendo…' : p[campo] ? '📷 Cambiar' : '📷 Subir'}
                              <input type="file" accept="image/*" hidden disabled={subiendo === p.id + campo} onChange={(e) => { subirFoto(p, e.target.files?.[0], campo); e.target.value = '' }} />
                            </label>
                            {p[campo] && <button onClick={() => quitarFoto(p, campo)}>Quitar</button>}
                          </div>
                        </div>
                      ))}
                    </div>
                    <Campo label="Nombre"><input value={form.nombre} onChange={(e) => setForm({ ...form, nombre: e.target.value })} /></Campo>
<div className="form">
                    <Campo label="Marca"><input list="cat-marcas" value={form.marca} onChange={(e) => setForm({ ...form, marca: e.target.value })} placeholder="Ej.: Lattafa" /></Campo>
                    <Campo label="Género">
                      <select value={form.genero} onChange={(e) => setForm({ ...form, genero: e.target.value })}>
                        <option value="">Sin definir</option><option value="mujer">Mujer</option><option value="hombre">Hombre</option><option value="unisex">Unisex</option>
                      </select>
                    </Campo>
            </div>
                    <Campo label="Descripción (se ve en la tienda y en el link de vendedoras)">
                      <textarea rows="4" value={form.descripcion} onChange={(e) => setForm({ ...form, descripcion: e.target.value })} placeholder="Para quién es, cuándo usarlo, duración…" />
                    </Campo>
                    <Campo label="Notas y tonos (tienda y vendedoras)"><input value={form.notas} onChange={(e) => setForm({ ...form, notas: e.target.value })} placeholder="Salida: bergamota · Corazón: rosa · Fondo: ámbar" /></Campo>
                    <Campo label="Tips para vender (solo las vendedoras lo ven)"><textarea rows="2" value={form.tips_venta} onChange={(e) => setForm({ ...form, tips_venta: e.target.value })} placeholder="Ej.: ideal para regalo; huele parecido a …" /></Campo>
                    <div className="form">
                      <Campo label="🛒 Precio tienda $" ayuda={costo > 0 && form.precio_detal ? `Ganas ${pct((num(form.precio_detal) - costo) / costo)} sobre el costo` : 'Lo que paga el público'}>
                        <input type="number" step="0.01" min="0" inputMode="decimal" value={form.precio_detal} onChange={(e) => setForm({ ...form, precio_detal: e.target.value })} />
                      </Campo>
                      <Campo label="📦 Precio mayor $" ayuda={costo > 0 && form.precio_mayor ? `Ganas ${pct((num(form.precio_mayor) - costo) / costo)}` : 'Público, desde 12 perfumes'}>
                        <input type="number" step="0.01" min="0" inputMode="decimal" value={form.precio_mayor} onChange={(e) => setForm({ ...form, precio_mayor: e.target.value })} />
                      </Campo>
                      <Campo label="🤝 Consignación $" ayuda={costo > 0 && form.precio_consigna ? `Ganas ${pct((num(form.precio_consigna) - costo) / costo)}` : 'Lo que te debe la vendedora'}>
                        <input type="number" step="0.01" min="0" inputMode="decimal" value={form.precio_consigna} onChange={(e) => setForm({ ...form, precio_consigna: e.target.value })} />
                      </Campo>
                      <Campo label="Costo (de tus compras)" ayuda={costo > 0 ? 'Viene del inventario' : 'Aún sin compras'}><input value={costo > 0 ? usd(costo) : '—'} disabled /></Campo>
                      <Campo label="Existencia" ayuda={enInventario(p) ? `Sale del inventario (${existencia(p)})` : 'Anótala a mano porque no está en inventario'}>
                        <input type="number" min="0" inputMode="numeric" value={enInventario(p) ? existencia(p) : form.existencia_manual} disabled={enInventario(p)} onChange={(e) => setForm({ ...form, existencia_manual: e.target.value })} />
                      </Campo>
                    </div>
                    {fPrecios.length > 0 && <div className="aviso error"><b>Estos precios no cuadran:</b><ul>{fPrecios.map((a) => <li key={a}>{a}</li>)}</ul></div>}
                    <div className="cat-switches">
                      <label><input type="checkbox" checked={form.visible_tienda} onChange={(e) => setForm({ ...form, visible_tienda: e.target.checked })} /> Mostrar en la tienda online</label>
                      <label><input type="checkbox" checked={form.visible_vendedoras} onChange={(e) => setForm({ ...form, visible_vendedoras: e.target.checked })} /> Mostrar a las vendedoras (si tiene consignación)</label>
                    </div>
                    <button className="primario" onClick={() => guardar(p)}>Guardar cambios</button>
                  </div>
                )}
              </article>
            )
          })}
          {!filas.length && <p className="vacio">No hay perfumes con ese filtro.</p>}
        </div>
      </Seccion>
    </>
  )
}
