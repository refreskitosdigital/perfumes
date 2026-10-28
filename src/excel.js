// Descargas en Excel. La librería se carga solo cuando se usa (no pesa en el resto de la app).
export async function descargarExcel(nombre, hojas) {
  const XLSX = await import('xlsx')
  const libro = XLSX.utils.book_new()
  Object.entries(hojas).forEach(([titulo, filas]) => {
    const ws = XLSX.utils.json_to_sheet(filas.length ? filas : [{ aviso: 'Sin registros' }])
    ws['!cols'] = Object.keys(filas[0] || { aviso: 1 }).map((k) => ({ wch: Math.min(40, Math.max(k.length, ...filas.slice(0, 200).map((r) => String(r[k] ?? '').length)) + 2) }))
    XLSX.utils.book_append_sheet(libro, ws, titulo.replace(/[\\/?*[\]:]/g, ' ').slice(0, 31))
  })
  XLSX.writeFile(libro, `${nombre}-${new Date().toLocaleDateString('en-CA', { timeZone: 'America/Caracas' })}.xlsx`)
}
