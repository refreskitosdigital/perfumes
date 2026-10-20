import { useCallback, useEffect, useState } from 'react'

// Carga datos con una función async que devuelve { data, error }
export function useQuery(fn, deps = []) {
  const [data, setData] = useState([])
  const [error, setError] = useState(null)
  const [cargando, setCargando] = useState(true)
  const recargar = useCallback(async () => {
    setCargando(true)
    const r = await fn()
    if (r.error) setError(r.error.message)
    else { setError(null); setData(r.data ?? []) }
    setCargando(false)
  }, deps) // eslint-disable-line
  useEffect(() => { recargar() }, [recargar])
  return { data, error, cargando, recargar }
}
