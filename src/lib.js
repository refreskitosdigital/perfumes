// Reglas de negocio (equivalen a las fórmulas del Excel)

export const num = (v) => {
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

// Factor Binance/BCV (≈1.1576): cuántos BCV$ vale 1 $ de divisa real
export const factor = (bcv, binance) => (num(bcv) > 0 ? num(binance) / num(bcv) : 1)

// Descuento máximo por pagar en divisa (≈13.6 %)
export const descuentoMax = (bcv, binance) => (num(binance) > 0 ? 1 - num(bcv) / num(binance) : 0)

// Precio de lista en BCV$ -> lo que pagan en Bs y lo que pagan en divisa
export const precioBs = (lista, bcv) => num(lista) * num(bcv)
export const precioDivisa = (lista, bcv, binance) =>
  num(binance) > 0 ? (num(lista) * num(bcv)) / num(binance) : num(lista)

// Precio sugerido para ganar X % (sobre costo o sobre venta), redondeado hacia arriba
export function precioSugerido(costo, ganancia = 0.3, base = 'costo', redondeo = 0.5) {
  const c = num(costo)
  if (c <= 0) return 0
  const bruto = base === 'venta' ? c / (1 - ganancia) : c * (1 + ganancia)
  const r = num(redondeo) > 0 ? num(redondeo) : 0.01
  return Math.ceil(Math.round((bruto / r) * 1e6) / 1e6) * r
}

// Precio unitario según cantidad (al mayor desde el umbral)
export function precioPorCantidad(perfume, unidades, umbral = 6) {
  if (!perfume) return 0
  const detal = num(perfume.precio_detal)
  const mayor = perfume.precio_mayor != null ? num(perfume.precio_mayor) : detal
  return num(unidades) >= umbral ? mayor : detal
}

// Valor real de una venta en $. Si el precio está en BCV$, equivale a total × BCV / Binance
export const valorVenta = (base, total, bcv, binance) =>
  base === 'bcv' && num(binance) > 0 ? (num(total) * num(bcv)) / num(binance) : num(total)

// Lo cobrado en $: los Bs se valoran con la tasa Binance (con la que se repone la divisa)
export const cobradoUsd = ({ bs = 0, efectivo = 0, binance = 0 }, tasaBinance) =>
  num(efectivo) + num(binance) + (num(tasaBinance) > 0 ? num(bs) / num(tasaBinance) : 0)

export const usd = (v) => '$' + num(v).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
export const bs = (v) => 'Bs ' + num(v).toLocaleString('es-VE', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
export const pct = (v) => (v == null ? '—' : (num(v) * 100).toLocaleString('es-VE', { maximumFractionDigits: 1 }) + ' %')
export const hoy = () => new Date().toLocaleDateString('en-CA', { timeZone: 'America/Caracas' })
