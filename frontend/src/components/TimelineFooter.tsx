import { useEffect, useState } from 'react'

export default function TimelineFooter() {
  const [points, setPoints] = useState<number[]>([])

  useEffect(() => {
    const fetcher = async () => {
      try {
        const res = await fetch('http://localhost:8080/api/tile-status')
        if (res.ok) {
          const json = await res.json()
          // Simulate historical data points for demo
          const currentRatio = json.fresh_count / (json.fresh_count + json.stale_count)
          const simulatedHistory = Array.from({ length: 48 }, (_, i) => {
            // Create some variation around the current ratio
            const variation = (Math.sin(i * 0.3) * 0.02) + (Math.random() * 0.01 - 0.005)
            return Math.max(0, Math.min(1, currentRatio + variation))
          })
          setPoints(simulatedHistory)
        }
      } catch (error) {
        console.error('Failed to fetch tile status:', error)
      }
    }
    fetcher()
    const id = setInterval(fetcher, 60_000)
    return () => clearInterval(id)
  }, [])

  return (
    <footer className="timeline sticky bottom-0 h-28 border-t border-neutral-800 bg-neutral-950 p-4">
      {!points.length ? (
        <p className="text-neutral-400 text-sm">Loading history…</p>
      ) : (
        <svg width="100%" height="100%">
          {points.map((v, i) => {
            const x = (i / (points.length - 1)) * 100
            const y = 100 - (v / Math.max(...points)) * 100
            return (
              <circle
                key={i}
                cx={`${x}%`}
                cy={`${y}%`}
                r="2.5"
                fill="#22c55e"
              />
            )
          })}
        </svg>
      )}
    </footer>
  )
}
