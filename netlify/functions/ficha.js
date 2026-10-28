// Vista previa de un perfume para WhatsApp: /p/ID devuelve una página mínima con foto, nombre y precio
// (para que el enlace se vea bonito al compartirlo) y manda a la persona a la tienda, que abre la ficha.
// Corre en Netlify (plan gratuito). Solo usa la clave anon y la función pública tienda_catalogo.
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))

export default async (request) => {
  const url = new URL(request.url)
  const id = (url.pathname.match(/\/p\/(\d+)/) || [])[1] || url.searchParams.get('id') || ''
  const modo = (process.env.VITE_MODO || '').toLowerCase()
  const destino = `${url.origin}${modo === 'tienda' ? '/' : '/tienda'}?p=${encodeURIComponent(id)}`
  let p = null
  try {
    const base = (process.env.VITE_SUPABASE_URL || '').replace(/\/+$/, '')
    const key = process.env.VITE_SUPABASE_ANON_KEY || ''
    if (base && key && /^\d+$/.test(id)) {
      const r = await fetch(`${base}/rest/v1/rpc/tienda_catalogo`, {
        method: 'POST', headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, body: '{}',
      })
      if (r.ok) p = (await r.json()).find((x) => String(x.id) === id) || null
    }
  } catch { /* si falla, igual redirige */ }
  const titulo = p ? `${p.nombre}${p.precio_detal != null ? ' · $' + Number(p.precio_detal).toFixed(2).replace(/\.00$/, '') : ''}` : 'Perfumes'
  const desc = p ? (p.descripcion || `${p.marca ? p.marca + '. ' : ''}Pídelo por WhatsApp.`).slice(0, 200) : 'Mira el catálogo completo de perfumes.'
  const img = p?.foto_url ? `<meta property="og:image" content="${esc(p.foto_url)}">` : ''
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(titulo)}</title>
<meta property="og:type" content="product"><meta property="og:title" content="${esc(titulo)}"><meta property="og:description" content="${esc(desc)}">${img}
<meta name="twitter:card" content="summary_large_image"><meta http-equiv="refresh" content="0;url=${esc(destino)}"></head>
<body><p><a href="${esc(destino)}">Ver ${esc(titulo)}</a></p><script>location.replace(${JSON.stringify(destino)})</script></body></html>`
  return new Response(html, { status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=300' } })
}
