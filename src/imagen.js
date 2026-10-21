// Reduce una imagen (lado mayor = max px) y la devuelve como JPG, para que la tienda cargue rápido
export const reducirImagen = (archivo, max = 900, calidad = 0.85) => new Promise((resolve, reject) => {
  const img = new Image(); const url = URL.createObjectURL(archivo)
  img.onload = () => {
    const k = Math.min(1, max / Math.max(img.width, img.height))
    const c = document.createElement('canvas'); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k)
    const ctx = c.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height); ctx.drawImage(img, 0, 0, c.width, c.height)
    URL.revokeObjectURL(url)
    c.toBlob((b) => (b ? resolve(b) : reject(new Error('No se pudo procesar la foto'))), 'image/jpeg', calidad)
  }
  img.onerror = () => reject(new Error('Ese archivo no es una imagen válida'))
  img.src = url
})
