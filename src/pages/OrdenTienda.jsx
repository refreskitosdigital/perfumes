import React, { useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../supabase.js'
import { useApp } from '../App.jsx'
import { Seccion, Aviso, Guia } from '../ui.jsx'
import Botella from '../tienda/Botella.jsx'
import { usd } from '../lib.js'

// Vista del catálogo: así se ve la tienda (fotos pequeñas). Se arrastra con el mouse para cambiar el orden
// (arriba, abajo, izquierda, derecha). En el teléfono se usan los botones ◀ ▶ ⤒. El orden se guarda al soltar.
export default function OrdenTienda({ stock }) {
  const { perfumes, recargarPerfumes } = useApp()
  const [lista, setLista] = useState([])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [arrastra, setArrastra] = useState(null)       // posición del perfume que se está moviendo
  const [buscar, setBuscar] = useState('')
  const [genero, setGenero] = useState('todos')
  const moviendo = useRef(false)
  const orden = useRef([])                              // copia sin esperar al render, para guardar al soltar

  useEffect(() => {
    if (moviendo.current) return
    const o = [...perfumes.data].sort((a, b) => (a.orden ?? 1e9) - (b.orden ?? 1e9) || a.nombre.localeCompare(b.nombre, 'es'))
    orden.current = o; setLista(o)
  }, [perfumes.data])

  const guardar = async (nueva) => {
    orden.current = nueva; setLista(nueva)
    const { error } = await supabase.rpc('perfumes_ordenar', { p_ids: nueva.map((p) => p.id) })
    if (error) return setMsg({ error: /perfumes_ordenar|orden/.test(error.message) ? 'Falta ejecutar migracion_v11.sql en Supabase.' : error.message, ok: '' })
    setMsg({ error: '', ok: 'Orden guardado. Ya se ve así en la tienda.' })
    recargarPerfumes()
  }
  const mover = (desde, hasta) => {
    if (desde === hasta || hasta < 0 || hasta >= orden.current.length) return
    const n = [...orden.current]; const [x] = n.splice(desde, 1); n.splice(hasta, 0, x); guardar(n)
  }
  // Mientras se arrastra solo se reacomoda en pantalla; se guarda una vez, al soltar
  const alEntrar = (i) => {
    if (arrastra == null || arrastra === i) return
    const n = [...orden.current]; const [x] = n.splice(arrastra, 1); n.splice(i, 0, x)
    orden.current = n; setLista(n); setArrastra(i)
  }
  const soltar = () => {
    if (!moviendo.current) return
    moviendo.current = false; setArrastra(null)
    guardar(orden.current)
  }
  const visibilidad = async (p, visible) => {
    const { error } = await supabase.from('perfumes').update({ visible_tienda: visible }).eq('id', p.id)
    if (error) return setMsg({ error: error.message, ok: '' })
    setMsg({ error: '', ok: visible ? `${p.nombre} vuelve a mostrarse en la tienda.` : `${p.nombre} ya no se muestra en la tienda (no se borra).` })
    recargarPerfumes()
  }

  const q = buscar.trim().toLowerCase()
  const filtrando = !!q || genero !== 'todos'
  const filas = useMemo(() => lista.map((p, i) => ({ p, i })).filter(({ p }) =>
    (!q || (p.nombre + ' ' + (p.marca || '')).toLowerCase().includes(q)) && (genero === 'todos' || p.genero === genero)), [lista, q, genero])
  const primeros = lista.filter((p) => p.visible_tienda !== false).slice(0, 3).map((p) => p.nombre)
  const ocultos = lista.filter((p) => p.visible_tienda === false).length

  return (
    <Seccion titulo="Vista del catálogo" ayuda="Así se ve tu tienda. Mantén el clic sobre un perfume y arrástralo a donde quieras: arriba, abajo, izquierda o derecha."
      acciones={<span className="ayuda">{lista.length - ocultos} visibles{ocultos ? ` · ${ocultos} ocultos` : ''}</span>}>
      <Guia>Arrastra cada perfume para cambiarlo de lugar; el cambio se guarda al soltar. En el teléfono usa <b>◀ ▶</b> y <b>⤒</b> (al inicio). Con <b>✕</b> lo quitas de la tienda sin borrarlo de tus datos, y con <b>👁</b> vuelve a mostrarse. Para arrastrar, quita primero el buscador y el filtro de género.</Guia>
      <div className="atajos">
        <input className="buscador" placeholder="🔍 Buscar marca o perfume" value={buscar} onChange={(e) => setBuscar(e.target.value)} />
        {[['todos', 'Todos'], ['mujer', 'Mujer'], ['hombre', 'Hombre'], ['unisex', 'Unisex']].map(([k, n]) => (
          <button key={k} className={genero === k ? 'primario' : ''} onClick={() => setGenero(k)}>{n}</button>
        ))}
      </div>
      <Aviso {...msg} />
      <p className="ayuda"><b>Lo primero que ve el cliente:</b> {primeros.length ? primeros.join(' · ') : '—'}</p>
      <div className="orden-grid" onDragOver={(e) => e.preventDefault()} onDrop={(e) => { e.preventDefault(); soltar() }}>
        {filas.map(({ p, i }) => {
          const oculto = p.visible_tienda === false
          const agotado = stock && stock[p.id] != null && stock[p.id] < 1
          return (
            <div key={p.id} draggable={!filtrando}
              className={'orden-ficha' + (arrastra === i ? ' arrastrando' : '') + (oculto ? ' oculto' : '')}
              onDragStart={(e) => { moviendo.current = true; setArrastra(i); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', String(p.id)) }}
              onDragEnter={() => alEntrar(i)}
              onDragEnd={soltar}>
              <span className="orden-pos">{i + 1}</span>
              <button className="orden-ojo" onClick={() => visibilidad(p, oculto)} aria-label={oculto ? `Mostrar ${p.nombre}` : `Ocultar ${p.nombre}`} title={oculto ? 'Mostrar en la tienda' : 'Quitar de la tienda'}>{oculto ? '👁' : '✕'}</button>
              <div className="orden-foto">
                {p.foto_url ? <img src={p.foto_url} alt="" draggable="false" loading="lazy" /> : <Botella nombre={p.nombre} chico />}
              </div>
              <b className="orden-nombre-g">{p.nombre}</b>
              <small>{p.precio_detal != null ? usd(p.precio_detal) : 'sin precio'}{agotado ? ' · por llegar' : ''}{oculto ? ' · oculto' : ''}</small>
              {!filtrando && (
                <span className="orden-mini">
                  <button onClick={() => mover(i, 0)} aria-label="Al inicio" title="Al inicio">⤒</button>
                  <button onClick={() => mover(i, i - 1)} aria-label="Una posición antes" disabled={i === 0}>◀</button>
                  <button onClick={() => mover(i, i + 1)} aria-label="Una posición después" disabled={i === lista.length - 1}>▶</button>
                </span>
              )}
            </div>
          )
        })}
      </div>
    </Seccion>
  )
}
