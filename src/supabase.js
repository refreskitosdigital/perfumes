import { createClient } from '@supabase/supabase-js'
// La URL y la clave "anon public" son públicas por diseño (la seguridad la da RLS en la base de datos).
// Si defines VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY en Netlify, tienen prioridad sobre estos valores.
const url = import.meta.env.VITE_SUPABASE_URL || 'https://qknkgyttfbbvlncvxvrw.supabase.co'
const key = import.meta.env.VITE_SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFrbmtneXR0ZmJidmxuY3Z4dnJ3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NjI4MTAsImV4cCI6MjEwODAzODgxMH0.7TyT2uRGIrhCHlAFLfWF6jJTSrZ4vuPdn4CltO5nWBg'
export const configurado = Boolean(url && key)
export const supabase = createClient(url, key)
