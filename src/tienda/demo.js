// Datos de ejemplo SOLO para la vista previa. La tienda real lee todo de Supabase.
const svgBanner = (fondo, acento, titulo, sub, tag) => {
  const s = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 640">
<rect width="1920" height="640" fill="${fondo}"/>
<circle cx="1500" cy="320" r="360" fill="${acento}" opacity=".92"/>
<circle cx="1500" cy="320" r="250" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="2"/>
<g transform="translate(1390 120)"><rect x="82" y="0" width="76" height="60" rx="6" fill="#1c2311"/><rect x="100" y="60" width="40" height="26" fill="#8a8189"/><rect x="20" y="86" width="200" height="300" rx="28" fill="#fff" fill-opacity=".22" stroke="#fff" stroke-width="4"/><rect x="28" y="230" width="184" height="148" rx="22" fill="#1c2311"/><rect x="70" y="150" width="100" height="44" rx="4" fill="#fff" fill-opacity=".92"/></g>
<text x="140" y="210" fill="#fff" fill-opacity=".8" font-family="Jost,Arial,sans-serif" font-size="30" letter-spacing="6">${tag}</text>
<text x="140" y="330" fill="#fff" font-family="'Bodoni Moda',Georgia,serif" font-size="108">${titulo}</text>
<text x="140" y="410" fill="#fff" fill-opacity=".85" font-family="Jost,Arial,sans-serif" font-size="38">${sub}</text>
</svg>`
  return 'data:image/svg+xml;utf8,' + encodeURIComponent(s)
}

const DESC = { 'Ariana Grande Cloud': 'Dulce y aireado: pera, coco y praliné. Suave, para todos los días.', 'Santal 33': 'Madera de sándalo, cuero y cardamomo. Amaderado y elegante.', 'Yara Fem Lattafa': 'Vainilla cremosa con orquídea y fruta tropical. Llega pronto.' }
const perfumes = [
  ['Carolina Herrera Good Girl', 30, 24, 1, 18], ['Invictus Parfum Paco Rabanne', 40, 32, 7, 12],
  ['Lattafa Art of Universe', 35, 28, 1, 9], ['Fantasy', 25, 20, 2, 7], ['Santal 33', 32, 26, 2, 6],
  ['Ariana Grande Cloud', 36, 29, 24, 5], ['Ariana Grande Mod Blush', 36, 29, 6, 4], ['Asad Lattafa', 32, 26, 12, 4],
  ['Bharara Rose', 36, 29, 4, 3], ['One Million Paco Rabanne', 36, 29, 5, 3], ['Yara Candy Lattafa', 32, 26, 9, 3],
  ['Perry Ellis 360', 32, 26, 1, 2], ['Valentino Donna Intense', 38, 31, 5, 2], ['9 PM Night Out', 35, 28, 3, 2],
  ['Afnan 9am Femme', 25, 20, 0, 5], ['Armaf Beach Party', 45, 36, 0, 4], ['Lattafa Khamrah Qahwa', 40, 32, 0, 3], ['Yara Fem Lattafa', null, null, 12, 0], ['Odyssey Tyrant', null, null, 13, 0],
  ['La Bomba Carolina Herrera', 40, 32, 0, 2],
].map(([nombre, d, m, stock, v], i) => ({ id: i + 1, nombre, precio_detal: d, precio_mayor: m, stock, foto_url: null, foto2_url: null, vendidos: v, descripcion: DESC[nombre] || null }))

const info = {
  nombre: 'MOTOSA PARFUM', whatsapp: '584241735215', umbral_mayor: 12,
  mensaje: 'Perfumes árabes y de diseñador, listos para entrega.',
  metodos: [
    { titulo: 'Pago móvil / transferencia en Bs', detalle: 'Te enviamos los datos por WhatsApp al confirmar.' },
    { titulo: 'Efectivo en dólares', detalle: 'Al momento de la entrega.' },
    { titulo: 'Binance (USDT)', detalle: 'Te enviamos el ID por WhatsApp al confirmar.' },
  ],
  banners: [
    svgBanner('#1c2311', '#c8a14a', 'Promoción del mes', 'Perfumes árabes y de diseñador, al detal y al mayor', 'OCTUBRE'),
    svgBanner('#2c3818', '#8a9a3b', 'Con 12 perfumes, precio al mayor', 'Pueden ser 12 diferentes y todo pasa a precio mayor', 'AL MAYOR'),
    svgBanner('#161b0d', '#a8832f', 'Agenda lo agotado', 'Te avisamos por WhatsApp apenas lo traigamos', 'NUEVOS INGRESOS'),
  ],
  tasa: { fecha: '2026-10-21', euro: 1030 },
}

let cat = perfumes.map((p) => ({ ...p }))
let n = 0
const ok = (data) => Promise.resolve({ data, error: null })
const fallo = (m) => Promise.resolve({ data: null, error: { message: m } })

export function demoRpc(nombre, a = {}) {
  if (nombre === 'tienda_catalogo') return ok(cat.map((p) => ({ ...p })))
  if (nombre === 'tienda_info') return ok(info)
  if (nombre === 'tienda_agendar') return ok(null)
  if (nombre === 'tienda_crear_pedido') {
    if (!a.p_nombre || !a.p_apellido) return fallo('Escribe tu nombre y apellido')
    const items = a.p_items || []
    const unid = items.reduce((s, i) => s + i.unidades, 0)
    const mayor = unid >= info.umbral_mayor
    let total = 0
    for (const it of items) {
      const p = cat.find((x) => x.id === it.perfume_id)
      if (!p || it.unidades > p.stock) return fallo('Ese perfume ya no está disponible')
      total += it.unidades * (mayor ? p.precio_mayor : p.precio_detal)
    }
    items.forEach((it) => { const p = cat.find((x) => x.id === it.perfume_id); p.stock -= it.unidades })
    n += 1
    return ok({ codigo: 'W-' + String(n).padStart(3, '0'), total, mayor })
  }
  return fallo('No disponible en la vista previa')
}
