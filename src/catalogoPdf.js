// Catálogo en PDF para compartir: foto, marca, nombre y notas de cada perfume. NUNCA lleva precios ni existencias.
const TINTA = [28, 35, 17], ORO = [200, 161, 74], PAPEL = [248, 247, 241], CREMA = [239, 234, 219], GRIS = [90, 93, 76]
const GEN = { mujer: 'Para ella', hombre: 'Para él', unisex: 'Unisex' }
const tel = (n) => { const d = String(n || '').replace(/\D/g, ''); return d.startsWith('58') && d.length === 12 ? `0${d.slice(2, 5)}-${d.slice(5)}` : (n || '') }

// Descarga una foto y la reduce a JPEG (si el navegador no la deja leer, devuelve null y se dibuja un recuadro)
export function cargarFoto(url) {
  return new Promise((resolve) => {
    if (!url) return resolve(null)
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => {
      try {
        const k = Math.min(1, 700 / Math.max(img.naturalWidth, img.naturalHeight))
        const c = document.createElement('canvas'); c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k)
        const g = c.getContext('2d'); g.fillStyle = '#efeadb'; g.fillRect(0, 0, c.width, c.height); g.drawImage(img, 0, 0, c.width, c.height)
        resolve({ data: c.toDataURL('image/jpeg', 0.82), w: c.width, h: c.height })
      } catch { resolve(null) }
    }
    img.onerror = () => resolve(null)
    img.src = url
  })
}

export function ordenarCatalogo(perfumes) {
  const m = (p) => (p.marca || '').trim()
  return [...perfumes].sort((a, b) => (!m(a) - !m(b)) || m(a).localeCompare(m(b), 'es') || a.nombre.localeCompare(b.nombre, 'es'))
}

export async function crearCatalogoPdf({ perfumes, tienda = {}, incluirNotas = true, fecha = '', cargar = cargarFoto, alProgreso = () => {}, archivo = 'catalogo.pdf', descargar = true }) {
  const { jsPDF } = await import('jspdf')
  const doc = new jsPDF({ unit: 'pt', format: 'a4' })
  const W = doc.internal.pageSize.getWidth(), H = doc.internal.pageSize.getHeight()
  const nombreTienda = (tienda.nombre || 'MOTOSA PARFUM').toUpperCase()
  const lista = ordenarCatalogo(perfumes)

  // Portada
  doc.setFillColor(...TINTA); doc.rect(0, 0, W, H, 'F')
  doc.setDrawColor(...ORO); doc.setLineWidth(0.8); doc.line(W / 2 - 40, 330, W / 2 + 40, 330)
  doc.setTextColor(255, 255, 255); doc.setFont('times', 'normal'); doc.setFontSize(34)
  { const ancho = doc.getTextWidth(nombreTienda) + 5 * (nombreTienda.length - 1); doc.text(nombreTienda, (W - ancho) / 2, 300, { charSpace: 5 }) }
  doc.setTextColor(...ORO); doc.setFontSize(17)
  doc.text('Catálogo de perfumes', W / 2, 372, { align: 'center' })
  doc.setFont('helvetica', 'normal'); doc.setFontSize(10.5); doc.setTextColor(212, 214, 196)
  doc.text(`${lista.length} perfumes${fecha ? ' · ' + fecha : ''}`, W / 2, 396, { align: 'center' })
  doc.setFontSize(10)
  doc.text('Consulta precios y disponibilidad por WhatsApp' + (tienda.whatsapp ? ': ' + tel(tienda.whatsapp) : ''), W / 2, H - 70, { align: 'center' })

  // Páginas de productos: 3 columnas x 3 filas
  const M = 36, GAP = 14, COLS = 3, FILAS = 3
  const cw = (W - 2 * M - GAP * (COLS - 1)) / COLS
  const foto = cw, texto = 66, ch = foto + texto, top = 62
  const porPagina = COLS * FILAS
  const paginas = Math.max(1, Math.ceil(lista.length / porPagina))
  for (let i = 0; i < lista.length; i++) {
    if (i % porPagina === 0) {
      doc.addPage(); doc.setFillColor(...PAPEL); doc.rect(0, 0, W, H, 'F')
      doc.setFont('times', 'normal'); doc.setFontSize(12); doc.setTextColor(...TINTA); doc.text(nombreTienda, M, 38, { charSpace: 2.5 })
      doc.setFont('helvetica', 'normal'); doc.setFontSize(9); doc.setTextColor(...GRIS); doc.text('Catálogo de perfumes', W - M, 38, { align: 'right' })
      doc.setDrawColor(...ORO); doc.setLineWidth(0.6); doc.line(M, 46, W - M, 46)
    }
    const k = i % porPagina, col = k % COLS, fila = Math.floor(k / COLS)
    const x = M + col * (cw + GAP), y = top + fila * (ch + 16)
    const p = lista[i]
    doc.setFillColor(...CREMA); doc.rect(x, y, cw, foto, 'F')
    const f = await cargar(p.foto_url)
    if (f) {
      const r = Math.min((cw - 10) / f.w, (foto - 10) / f.h), w = f.w * r, h = f.h * r
      doc.addImage(f.data, 'JPEG', x + (cw - w) / 2, y + (foto - h) / 2, w, h)
    } else {
      doc.setFont('times', 'normal'); doc.setFontSize(44); doc.setTextColor(...ORO)
      doc.text((p.nombre || '?').trim()[0].toUpperCase(), x + cw / 2, y + foto / 2 + 14, { align: 'center' })
    }
    let ty = y + foto + 14
    if (p.marca || GEN[p.genero]) {
      doc.setFont('helvetica', 'bold'); doc.setFontSize(8); doc.setTextColor(...ORO)
      doc.text([p.marca, GEN[p.genero]].filter(Boolean).join(' · '), x, ty, { maxWidth: cw }); ty += 12
    }
    doc.setFont('times', 'normal'); doc.setFontSize(11.5); doc.setTextColor(...TINTA)
    const nom = doc.splitTextToSize(p.nombre, cw).slice(0, 2); doc.text(nom, x, ty); ty += nom.length * 13
    if (incluirNotas && p.notas) {
      doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(...GRIS)
      doc.text(doc.splitTextToSize(p.notas, cw).slice(0, 2), x, ty + 1)
    }
    if (k === porPagina - 1 || i === lista.length - 1) {
      const n = doc.getNumberOfPages() - 1
      doc.setFont('helvetica', 'normal'); doc.setFontSize(8.5); doc.setTextColor(...GRIS)
      doc.text('Consulta precios y disponibilidad por WhatsApp' + (tienda.whatsapp ? ': ' + tel(tienda.whatsapp) : ''), M, H - 26)
      doc.text(`${n} de ${paginas}`, W - M, H - 26, { align: 'right' })
    }
    alProgreso(i + 1, lista.length)
  }
  if (descargar) doc.save(archivo)
  return doc
}
