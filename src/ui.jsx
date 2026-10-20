import React from 'react'

export function Tarjeta({ titulo, valor, nota, tono }) {
  return (
    <div className={'tarjeta ' + (tono || '')}>
      <div className="t-titulo">{titulo}</div>
      <div className="t-valor">{valor}</div>
      {nota && <div className="t-nota">{nota}</div>}
    </div>
  )
}

export function Seccion({ titulo, ayuda, children, acciones }) {
  return (
    <section className="seccion">
      <header>
        <div>
          <h2>{titulo}</h2>
          {ayuda && <p className="ayuda">{ayuda}</p>}
        </div>
        {acciones}
      </header>
      {children}
    </section>
  )
}

export function Campo({ label, children, ayuda }) {
  return (
    <label className="campo">
      <span>{label}</span>
      {children}
      {ayuda && <small>{ayuda}</small>}
    </label>
  )
}

export function Tabla({ cols, filas, vacio = 'Sin registros todavía.' }) {
  if (!filas.length) return <p className="vacio">{vacio}</p>
  return (
    <div className="tabla-wrap">
      <table>
        <thead><tr>{cols.map((c) => <th key={c.k} className={c.num ? 'num' : ''}>{c.t}</th>)}</tr></thead>
        <tbody>
          {filas.map((f, i) => (
            <tr key={f.id ?? f.codigo ?? i}>
              {cols.map((c) => <td key={c.k} className={c.num ? 'num' : ''}>{c.f ? c.f(f) : f[c.k]}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function Aviso({ error, ok }) {
  if (error) return <div className="aviso error">{error}</div>
  if (ok) return <div className="aviso ok">{ok}</div>
  return null
}
