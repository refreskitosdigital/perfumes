import React from 'react'

// Colores por "familia olfativa". Se eligen por palabras del nombre y, si no hay pista, por el nombre mismo.
export const TONOS = {
  oud:      { fondo: '#E8DDD3', liquido: '#6B4A3A' },
  rosa:     { fondo: '#F6DFE5', liquido: '#C4476B' },
  ambar:    { fondo: '#F7E6C7', liquido: '#D58A1F' },
  citrico:  { fondo: '#ECF1CC', liquido: '#8DA42B' },
  azul:     { fondo: '#DCE7F3', liquido: '#3E6FA3' },
  violeta:  { fondo: '#E7DEF2', liquido: '#6C4BA0' },
  vainilla: { fondo: '#F8F0DD', liquido: '#C9A25B' },
  jade:     { fondo: '#D9EBE3', liquido: '#2F8466' },
}
const CLAVES = [
  [/vainilla|vanilla|vanille|coco|candy|cloud|lace/i, 'vainilla'],
  [/rose|rosa|blush|fem\b|girl|bella|angel|donna|toy boy|fantasy|mod /i, 'rosa'],
  [/asad|khamrah|oud|bestia|tyrant|amber|santal/i, 'oud'],
  [/sky|mandarin|citrus|coral|fresh|splash/i, 'citrico'],
  [/aqua|gio|blue|sauvage|bleu|360|club|mega|odyssey/i, 'azul'],
  [/invictus|one million|starwalker|bad boy|vip/i, 'ambar'],
  [/yara|9pm|night|noche|eclaire|moi/i, 'violeta'],
]
export function tonoDe(nombre) {
  for (const [re, t] of CLAVES) if (re.test(nombre)) return TONOS[t]
  const llaves = Object.keys(TONOS)
  let h = 0
  for (const c of String(nombre)) h = (h * 31 + c.charCodeAt(0)) >>> 0
  return TONOS[llaves[h % llaves.length]]
}
const forma = (nombre) => { let h = 7; for (const c of String(nombre)) h = (h * 17 + c.charCodeAt(0)) >>> 0; return h % 3 }

// Frasco ilustrado (se usa mientras un perfume no tiene foto)
export default function Botella({ nombre, tono = tonoDe(nombre), chico = false }) {
  const f = forma(nombre)
  return (
    <svg className={'botella' + (chico ? ' chica' : '')} viewBox="0 0 120 150" role="img" aria-label={nombre} focusable="false">
      <ellipse cx="60" cy="140" rx="34" ry="5" fill={tono.liquido} opacity=".16" />
      {f === 0 && (<>
        <rect x="50" y="14" width="20" height="18" rx="3" fill="#2A1630" />
        <rect x="54" y="30" width="12" height="8" fill={tono.liquido} opacity=".55" />
        <rect x="28" y="38" width="64" height="96" rx="22" fill="#fff" stroke={tono.liquido} strokeWidth="2" />
        <path d="M32 84 Q60 74 88 84 V114 a18 18 0 0 1 -18 18 H50 a18 18 0 0 1 -18 -18 Z" fill={tono.liquido} opacity=".85" />
      </>)}
      {f === 1 && (<>
        <rect x="46" y="12" width="28" height="22" rx="4" fill="#2A1630" />
        <rect x="52" y="32" width="16" height="9" fill={tono.liquido} opacity=".55" />
        <rect x="24" y="41" width="72" height="93" rx="6" fill="#fff" stroke={tono.liquido} strokeWidth="2" />
        <rect x="27" y="80" width="66" height="51" rx="3" fill={tono.liquido} opacity=".85" />
        <rect x="38" y="56" width="44" height="14" rx="2" fill="none" stroke={tono.liquido} strokeWidth="1.5" opacity=".6" />
      </>)}
      {f === 2 && (<>
        <circle cx="60" cy="20" r="10" fill="#2A1630" />
        <rect x="54" y="28" width="12" height="14" fill={tono.liquido} opacity=".55" />
        <path d="M60 42 L96 134 H24 Z" fill="#fff" stroke={tono.liquido} strokeWidth="2" strokeLinejoin="round" />
        <path d="M44 92 L76 92 L88 130 H32 Z" fill={tono.liquido} opacity=".85" />
      </>)}
      <path d="M38 52 q-4 20 -2 40" stroke="#fff" strokeWidth="4" strokeLinecap="round" opacity=".7" fill="none" />
    </svg>
  )
}
