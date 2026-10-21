// Genera las listas de precios en PDF para pasar a los clientes (solo nombres y precios, sin costos ni stock)
export async function crearListaPdf({ titulo, subtitulo, filas, nota, archivo, descargar = true }) {
  const { jsPDF } = await import('jspdf')
  const mod = await import('jspdf-autotable')
  const autoTable = mod.autoTable ?? mod.default?.default ?? mod.default
  const doc = new jsPDF({ unit: 'pt', format: 'a4' })
  const ancho = doc.internal.pageSize.getWidth()
  const MARRON = [122, 59, 46]

  doc.setFillColor(...MARRON)
  doc.rect(0, 0, ancho, 96, 'F')
  doc.setTextColor(255, 255, 255)
  doc.setFont('helvetica', 'bold'); doc.setFontSize(24)
  doc.text(titulo, 40, 50)
  doc.setFont('helvetica', 'normal'); doc.setFontSize(12)
  doc.text(subtitulo, 40, 74)

  autoTable(doc, {
    startY: 116,
    head: [['Perfume', 'Precio']],
    body: filas.map((f) => [f.nombre, f.precio]),
    theme: 'striped',
    styles: { font: 'helvetica', fontSize: 11.5, cellPadding: { top: 7, bottom: 7, left: 8, right: 8 }, textColor: [35, 28, 24] },
    headStyles: { fillColor: MARRON, textColor: 255, fontStyle: 'bold' },
    alternateRowStyles: { fillColor: [247, 241, 238] },
    columnStyles: { 1: { halign: 'right', fontStyle: 'bold', cellWidth: 90 } },
    margin: { left: 40, right: 40, bottom: 56 },
    didDrawPage: () => {
      const alto = doc.internal.pageSize.getHeight()
      doc.setFontSize(9); doc.setTextColor(120, 110, 104); doc.setFont('helvetica', 'normal')
      doc.text(nota, 40, alto - 30)
      doc.text('Pág. ' + doc.internal.getNumberOfPages(), ancho - 40, alto - 30, { align: 'right' })
    },
  })
  if (descargar) doc.save(archivo)
  return doc
}
