import test from 'node:test'
import assert from 'node:assert/strict'
import { factor, descuentoMax, precioSugerido, precioPorCantidad, precioDivisa, precioBs, valorVenta, cobradoUsd } from '../src/lib.js'

test('factor y descuento máximo', () => {
  assert.ok(Math.abs(factor(876.79, 1015) - 1.15764) < 1e-4)
  assert.ok(Math.abs(descuentoMax(876.79, 1015) - 0.13618) < 1e-4)
})
test('precio sugerido 30% sobre costo, redondeado a 0.50', () => {
  assert.equal(precioSugerido(21, 0.3, 'costo', 0.5), 27.5) // 27.3 -> 27.5
  assert.equal(precioSugerido(15, 0.3, 'costo', 0.5), 19.5) // 19.5 exacto
  assert.equal(precioSugerido(20, 0.3, 'venta', 0.5), 29)   // 28.57 -> 29
  assert.equal(precioSugerido(0), 0)
})
test('precio al mayor desde 6 unidades', () => {
  const p = { precio_detal: 35, precio_mayor: 30 }
  assert.equal(precioPorCantidad(p, 5), 35)
  assert.equal(precioPorCantidad(p, 6), 30)
  assert.equal(precioPorCantidad({ precio_detal: 35 }, 6), 35)
})
test('divisa vs Bs', () => {
  assert.ok(Math.abs(precioDivisa(35, 876.79, 1015) - 30.2333) < 1e-3)
  assert.ok(Math.abs(precioBs(35, 876.79) - 30687.65) < 1e-2)
})
test('valor real de la venta y cobros en Bs', () => {
  assert.equal(valorVenta('divisa', 40, 881, 1015), 40)
  assert.ok(Math.abs(valorVenta('bcv', 36, 881, 1015) - 31.2473) < 1e-3)       // Gina: 4 splash a $9 BCV
  const cobrado = cobradoUsd({ bs: 18 * 881 }, 1015)                           // pagó $18 en Bs
  assert.ok(Math.abs(cobrado - 15.6237) < 1e-3)
  assert.ok(Math.abs(valorVenta('bcv', 36, 881, 1015) - cobrado - 15.6237) < 1e-3) // lo que debe
  assert.equal(cobradoUsd({ efectivo: 20, binance: 5 }, 1015), 25)
})

import { normNombre, waLink, cajaUsd } from '../src/lib.js'
test('agrupa clientes sin importar tildes ni mayúsculas', () => {
  assert.equal(normNombre('  María  Fernanda '), normNombre('maria fernanda'))
})
test('enlace de WhatsApp venezolano', () => {
  assert.equal(waLink('0414-1234567'), 'https://wa.me/584141234567')
  assert.equal(waLink(''), null)
})
test('caja en dólares valora los Bs a Binance', () => {
  assert.equal(cajaUsd([{ cuenta: 'binance', saldo: 10 }, { cuenta: 'bs', saldo: 1015 }], 1015), 11)
})
