import { useEffect, useState } from 'react'

interface HeroData {
  maxLag: string
  tilesThisCycle: number
  totalTiles: number
}

export default function HeroStrip() {
  const [data, setData] = useState<HeroData | null>(null)

  useEffect(() => {
    const fetcher = async () => {
      const res = await fetch('http://localhost:8080/api/tile-status')
      if (res.ok) {
        const json = await res.json()
        setData({
          maxLag: '≤ 5 min',
          tilesThisCycle: json.fresh_count,
          totalTiles: json.fresh_count + json.stale_count,
        })
      }
    }
    fetcher()
    const id = setInterval(fetcher, 15_000)
    return () => clearInterval(id)
  }, [])

  return (
    <section className="hero flex gap-3 px-6 py-3 border-b border-neutral-800 bg-neutral-900 text-neutral-100 dark:bg-neutral-900">
      <Metric label="Max data lag" value={data?.maxLag ?? '—'} />
      <Metric
        label="Tiles regenerated"
        value={
          data ? `${((data.tilesThisCycle / data.totalTiles) * 100).toFixed(1)} %` : '—'
        }
      />
      <Metric
        label="Cycle size"
        value={data ? `${data.tilesThisCycle.toLocaleString()} / ${data.totalTiles.toLocaleString()}` : '—'}
      />
    </section>
  )
}

function Metric({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-full bg-neutral-800 px-4 py-1 text-sm flex items-center gap-2">
      <span className="font-semibold">{value}</span>
      <span className="opacity-60">{label}</span>
    </div>
  )
}
