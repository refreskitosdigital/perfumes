import { supabase } from '../supabase.js'
import { demoRpc } from './demo.js'

// En la vista previa (VITE_DEMO=1) la tienda usa datos de ejemplo, sin conectarse a Supabase.
export const esDemo = import.meta.env.VITE_DEMO === '1'
export const rpc = (nombre, args) => (esDemo ? demoRpc(nombre, args) : supabase.rpc(nombre, args))
