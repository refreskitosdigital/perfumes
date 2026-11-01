import React, { useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../supabase.js'
import { useApp } from '../App.jsx'
import { Seccion, Aviso, Guia, Insignia } from '../ui.jsx'

// Orden en que salen los perfumes en la tienda online y en la app de vendedoras.
// Se arrastra con el mouse (☰) o, en el teléfono, con las flechas ▲ ▼ / "Subir al inicio".
export default function OrdenTienda({ stock }) {
  const { perfumes, recargarPerfumes } = useApp()
  const [lista, setLista] = useState([])
  const [msg, setMsg] = useState({ error: '', ok: '' })
  const [arrastrando, setArrastrando] = useState(null)
  const [sobre, setSobre] = useState(null)
  const [buscar, setBuscar] = useState('')
  const [abierto, setAbierto] = useState(false)
  const guardando = useRef(false)

  useEffect(() => {
    const orden = [...perfumes.data].sort((a, b) => (a.orden ?? 1e9) - (b.orden ?? 1e9) || a.nombre.localeCompare(b.nombre, 'es'))
    setLista(orden)
  }, [perfumes.data])

  const guardar = async (nueva) => {
    setLista(nueva)
    guardando.current = true
    const { error } = await supabase.rpc('perfumes_ordenar', { p_ids: nueva.map((p) => p.id) })
    guardando.current = false
    if (error) return setMsg({ error: /perfumes_ordenar|orden/.test(error.message) ? 'Falta ejecutar migracion_v11.sql en Supabase.' : error.message, ok: '' })
    setMsg({ error: '', ok: 'Orden guardado. Ya se ve así en la tienda.' })
    recargarPerfumes()
  }
  const mover = (desde, hasta) => {
    if (desde === hasta || desde < 0 || hasta < 0 || hasta >= lista.length) return
    const n = [...lista]; const [x] = n.splice(desde, 1); n.splice(hasta, 0, x); guardar(n)
  }
  const porMarca = () => {
    if (!window.confirm('Se reordenan todos los perfumes por marca y nombre (se pierde tu orden manual). ¿Continuar?')) return
    const n = [...lista].sort((a, b) => (!!a.marca === !!b.marca ? 0 : a.marca ? -1 : 1) || (a.marca || '').localeCompare(b.marca || '', 'es') || a.nombre.localeCompare(b.nombre, 'es'))
    guardar(n)
  }

  const q = buscar.trim().toLowerCase()
  const filas = useMemo(() => lista.map((p, i) => ({ p, i })).filter(({ p }) => !q || (p.nombre + ' ' + (p.marca || '')).toLowerCase().includes(q)), [lista, q])

  return (
    <Seccion titulo="Orden en la tienda" ayuda="Así salen los perfumes en la tienda online y para las vendedoras, sin importar si hay stock."
      acciones={<button onClick={() => setAbierto(!abierto)}>{abierto ? 'Ocultar' : `Ordenar (${lista.length})`}</button>}>
      {abierto && (
        <>
          <Guia>Arrastra cada perfume por <b>☰</b> para ponerlo junto a los de marcas parecidas. En el teléfono usa <b>▲ ▼</b>. El cambio se guarda al soltar. Con la lupa puedes buscar una marca y moverla; los números muestran su posición real.</Guia>
          <div className="atajos">
            <input className="buscador" placeholder="🔍 Buscar marca o perfume" value={buscar} onChange={(e) => setBuscar(e.target.value)} />
            <button onClick={porMarca}>Ordenar por marca (A–Z)</button>
          </div>
          <Aviso {...msg} />
          <ol className="orden-lista">
            {filas.map(({ p, i }) => (
              <li key={p.id} draggable={!q}
                className={(arrastrando === i ? 'arrastrando ' : '') + (sobre === i && arrastrando !== null && arrastrando !== i ? 'sobre' : '')}
                onDragStart={(e) => { setArrastrando(i); e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', String(i)) }}
                onDragOver={(e) => { e.preventDefault(); setSobre(i) }}
                onDrop={(e) => { e.preventDefault(); if (arrastrando !== null) mover(arrastrando, i); setArrastrando(null); setSobre(null) }}
                onDragEnd={() => { setArrastrando(null); setSobre(null) }}>
                <span className="orden-asa" aria-hidden="true">{q ? '' : '☰'}</span>
                <span className="orden-n">{i + 1}</span>
                <span className="orden-nombre"><b>{p.nombre}</b>{p.marca && <small> · {p.marca}</small>}</span>
                {p.visible_tienda === false && <Insignia>oculto</Insignia>}
                {stock && stock[p.id] != null && stock[p.id] < 1 && <Insignia>por llegar</Insignia>}
                <span className="orden-botones">
                  <button onClick={() => mover(i, 0)} aria-label="Subir al inicio" title="Al inicio">⤒</button>
                  <button onClick={() => mover(i, i - 1)} aria-label="Subir" disabled={i === 0}>▲</button>
                  <button onClick={() => mover(i, i + 1)} aria-label="Bajar" disabled={i === lista.length - 1}>▼</button>
                </span>
              </li>
            ))}
          </ol>
        </>
      )}
    </Seccion>
  )
}
