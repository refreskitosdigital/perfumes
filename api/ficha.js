// Vercel: /p/ID -> vista previa del perfume para WhatsApp (misma lógica que netlify/functions/ficha.js)
import ficha from '../netlify/functions/ficha.js'
export const GET = (request) => ficha(request)
