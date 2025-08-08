import { useEffect, useRef, useState } from 'react'
import Map from './components/Map'
import './App.css'

interface TileStatus {
  tiles: any[]
  fresh_count: number
  stale_count: number
  last_check: string
}

interface SimulationStatus {
  is_running: boolean
  active_sessions: Array<{
    session_id: string
    percentage: number
    status: string
    started_at: string
    minutes_running: number
    minutes_until_timeout: number
  }>
}

interface SimulationResult {
  message: string
  percentage: number
  estimated_tiles: number
  session_id: string | null
  bbox_min_x: number
  bbox_min_y: number
  bbox_max_x: number
  bbox_max_y: number
}

function App() {
  const [tileStatus, setTileStatus] = useState<TileStatus | null>(null)
  const [simulationPercentage, setSimulationPercentage] = useState(7.5)
  const [isSimulating, setIsSimulating] = useState(false)
  const [mapRefreshTrigger, setMapRefreshTrigger] = useState(0)
  const [simulationStatus, setSimulationStatus] = useState<SimulationStatus | null>(null)
  const [lastSimulationBounds, setLastSimulationBounds] = useState<{
    bbox_min_x: number
    bbox_min_y: number
    bbox_max_x: number
    bbox_max_y: number
  } | null>(null)
  const [autoZoomTrigger, setAutoZoomTrigger] = useState(0)
  // Real timing state
  const [runStartTs, setRunStartTs] = useState<number | null>(null)
  const [measuredSeconds, setMeasuredSeconds] = useState<number | null>(null)
  const [extrapolatedSeconds, setExtrapolatedSeconds] = useState<number | null>(null)
  const lastBoundsRef = useRef<typeof lastSimulationBounds>(null)

  // Keep a ref to the latest bounds to avoid stale closures
  useEffect(() => {
    lastBoundsRef.current = lastSimulationBounds
  }, [lastSimulationBounds])

  const fetchData = async () => {
    try {
      const tileRes = await fetch('http://localhost:8080/api/tile-status')
      if (tileRes.ok) {
        const tileData = await tileRes.json()
        console.log('Fetched tile data:', tileData)
        console.log(`Fresh tiles: ${tileData.fresh_count}, Stale tiles: ${tileData.stale_count}`)
        setTileStatus(tileData)
      }
    } catch (error) {
      console.error('Error fetching data:', error)
    }
  }

  const fetchSimulationStatus = async () => {
    try {
      const statusRes = await fetch('http://localhost:8080/api/simulation-status')
      if (statusRes.ok) {
        const statusData = await statusRes.json()
        setSimulationStatus(statusData)
        return statusData
      }
    } catch (error) {
      console.error('Error fetching simulation status:', error)
    }
    return null
  }

  useEffect(() => {
    // Fetch initial data on component mount
    fetchData()
    fetchSimulationStatus()
  }, [])

  // Poll for simulation status when simulation is running
  useEffect(() => {
    if (!isSimulating) return

    let completedCount = 0
    const pollInterval = setInterval(async () => {
      const status = await fetchSimulationStatus()
      console.log('Polling simulation status:', status)
      
      if (status && !status.is_running && status.active_sessions.length === 0) {
        completedCount++
        // Wait for 2 consecutive polls to confirm completion
        if (completedCount >= 2) {
          // Simulation completed, refresh data and stop polling
          setIsSimulating(false)
          // Capture elapsed time
          const endTs = performance.now()
          if (runStartTs != null) {
            setMeasuredSeconds(Math.max(0, (endTs - runStartTs) / 1000))
          }
          fetchData()
          setMapRefreshTrigger(Date.now())
          console.log('Simulation completed, data refreshed automatically')
          
          // Trigger auto-zoom after a short delay to ensure data is refreshed
          setTimeout(() => {
            if (lastBoundsRef.current) {
              setAutoZoomTrigger(Date.now())
            }
          }, 1000) // Wait 1 second for data to refresh
        }
      } else {
        completedCount = 0
      }
    }, 1000) // Poll every second

    return () => clearInterval(pollInterval)
  }, [isSimulating])

  // Simple size estimate placeholder (until PMTiles writer reports real sizes)
  const AVG_TILE_BYTES = 2048 // ~2 KB per tile payload, demo estimate

  const formatSeconds = (seconds: number) => {
    if (seconds < 1) return `${Math.max(0, seconds * 1000).toFixed(0)} ms`
    if (seconds < 10) return `${seconds.toFixed(1)} s`
    return `${seconds.toFixed(0)} s`
  }

  const formatBytes = (bytes: number) => {
    if (bytes < 1024) return `${bytes} B`
    const kb = bytes / 1024
    if (kb < 1024) return `${kb.toFixed(1)} KB`
    const mb = kb / 1024
    if (mb < 1024) return `${mb.toFixed(1)} MB`
    const gb = mb / 1024
    return `${gb.toFixed(2)} GB`
  }

  const getEfficiencyRatio = () => {
    if (!tileStatus) return { timeRatio: 20, dataRatio: 20 }

    const totalTiles = tileStatus.fresh_count + tileStatus.stale_count
    const freshTiles = tileStatus.fresh_count

    if (freshTiles === 0) return { timeRatio: 1, dataRatio: 1 }

    const timeRatio = Math.round(totalTiles / Math.max(1, freshTiles))
    const dataRatio = Math.round(totalTiles / Math.max(1, freshTiles))

    return { timeRatio, dataRatio }
  }

  // Keep the efficiency calculation around for future metrics, but don't bind unused vars
  getEfficiencyRatio()
  const totalTiles = (tileStatus?.fresh_count || 0) + (tileStatus?.stale_count || 0)
  const freshTiles = tileStatus?.fresh_count || 0

  // Speed (real measured vs extrapolated full run)
  const speedProcessedLabel = measuredSeconds != null ? formatSeconds(measuredSeconds) : '—'
  const speedFullLabel = extrapolatedSeconds != null ? formatSeconds(extrapolatedSeconds) : '—'

  // Data size (processed vs full-run, rough estimate)
  const processedBytes = freshTiles * AVG_TILE_BYTES
  const fullRunBytes = totalTiles * AVG_TILE_BYTES
  const sizeProcessedLabel = tileStatus ? formatBytes(processedBytes) : '—'
  const sizeFullLabel = tileStatus ? formatBytes(fullRunBytes) : '—'

  // Savings (cache hit / tiles skipped)
  const tilesSkipped = tileStatus?.stale_count || 0
  const cacheHitPct = totalTiles > 0 ? (tilesSkipped / totalTiles) * 100 : 0

  const runSimulation = async () => {
    setIsSimulating(true)
    // Start timer for this run
    setMeasuredSeconds(null)
    setExtrapolatedSeconds(null)
    setRunStartTs(performance.now())
    try {
      const response = await fetch('http://localhost:8080/api/simulate', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ percentage: simulationPercentage }),
      })

      if (response.ok) {
        const simulationResult: SimulationResult = await response.json()
        console.log(`Started simulation with ${simulationPercentage}% of tiles`)
        console.log('Simulation bounding box:', {
          bbox_min_x: simulationResult.bbox_min_x,
          bbox_min_y: simulationResult.bbox_min_y,
          bbox_max_x: simulationResult.bbox_max_x,
          bbox_max_y: simulationResult.bbox_max_y
        })
        
        // Store the bounding box for auto-zoom (but don't trigger it yet)
        // We'll trigger the auto-zoom when the simulation completes
        setLastSimulationBounds({
          bbox_min_x: simulationResult.bbox_min_x,
          bbox_min_y: simulationResult.bbox_min_y,
          bbox_max_x: simulationResult.bbox_max_x,
          bbox_max_y: simulationResult.bbox_max_y
        })
        
        // The polling useEffect will handle the completion
        
        // Fallback: refresh data after 10 seconds regardless of polling
        setTimeout(() => {
          if (isSimulating) {
            console.log('Fallback: refreshing data after timeout')
            setIsSimulating(false)
            fetchData()
            setMapRefreshTrigger(Date.now())
          }
        }, 10000)
      } else {
        console.error('Failed to start simulation:', response.status)
        setIsSimulating(false)
      }
    } catch (error) {
      console.error('Error starting simulation:', error)
      setIsSimulating(false)
    }
  }

  // Compute extrapolated full-run time after we measure a run and receive updated counts
  useEffect(() => {
    if (measuredSeconds == null || !tileStatus) return
    const total = (tileStatus.fresh_count || 0) + (tileStatus.stale_count || 0)
    const fresh = tileStatus.fresh_count || 0
    if (fresh > 0) {
      const factor = total / fresh
      setExtrapolatedSeconds(measuredSeconds * factor)
    }
  }, [tileStatus, measuredSeconds])

  return (
    /* ------------------------------------------------------------------ */
    /* OUTER WRAPPER with gradient + grain + content                      */
    /* ------------------------------------------------------------------ */
    <div className="relative isolate min-h-screen overflow-hidden text-slate-200">
      {/* ─────────── Layer 1: Aurora gradient (animated, but motion-safe) ─────────── */}
      <div
        className="absolute inset-0 -z-30
                   bg-[radial-gradient(650px_at_10%_20%,rgba(255,176,189,0.35)_0%,transparent_60%),radial-gradient(800px_at_80%_0%,rgba(165,243,252,0.30)_0%,transparent_60%),radial-gradient(600px_at_80%_80%,rgba(186,230,253,0.30)_0%,transparent_60%),linear-gradient(to_bottom_right,#0f172a,#1e293b)]
                   motion-safe:animate-[aurora_20s_linear_infinite]"
      />

      {/* ───────── Layer 2: Subtle grain overlay (static) ───────── */}
      <div
        className="absolute inset-0 -z-20
                   bg-[url('data:image/svg+xml,%3csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%224%22 height=%224%22 fill=%22none%22%3e%3cpath d=%22M0 0h1v1H0zM2 1h1v1H2zM1 2h1v1H1zM3 3h1v1H3z%22 fill=%22rgba(255,255,255,0.9)%22/%3e%3c/svg%3e')]
                   opacity-10 mix-blend-overlay pointer-events-none"
      />

      {/* ─────────── Layer 3: Your existing app content ─────────── */}
      <div className="max-w-7xl mx-auto px-6 py-12">
        <div className="grid grid-cols-2 gap-16 items-start">
          {/* ───────────────────────── Left Side – Content ───────────────────────── */}
          <div className="flex flex-col h-full">
            <div>
              <h1 className="text-4xl font-bold bg-gradient-to-r from-cyan-300 via-fuchsia-300 to-sky-300 bg-clip-text text-transparent mb-5">
                JVT — Incremental Vector Tiles
              </h1>
              <p className="text-xl leading-relaxed mb-2">
                PostGIS‑native tiler built in Rust that regenerates only the tiles that changed.
                Event‑driven, containerized, and unopinionated about delivery.
              </p>
            </div>

            <div className="flex-1 space-y-6">
              {/* How it works */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">How it works</h2>
                <p className="leading-relaxed">
                  Database changes enqueue affected <code>z/x/y</code> tiles.
                  A Rust worker listens via PostgreSQL <code>LISTEN/NOTIFY</code>,
                  batches the queue, generates MVT with <code>ST_AsMVT</code>, and
                  writes results to your chosen sink (PMTiles or ZXY). Each batch
                  also emits a manifest so any pipeline can publish or cache as it prefers.
                </p>
              </div>

              {/* Tech stack */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">The technology stack</h2>
                <ul className="space-y-2">
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>PostGIS:</strong> change detection → tile queue
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>Rust:</strong> event‑driven worker, bounded concurrency
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>MVT:</strong> tiles from <code>ST_AsMVT(…)</code>
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>Outputs:</strong> PMTiles or ZXY + per‑batch manifest
                    </span>
                  </li>
                </ul>
              </div>

              {/* Why it matters */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">Why it matters</h2>
                <p className="leading-relaxed">
                  Stop nightly rebuilds. Update only what changed for lower compute,
                  faster freshness (≈ 5‑minute cadence), and CDN‑friendly delivery.
                  Works with object storage (on‑prem or cloud) or plain static hosting.
                </p>
              </div>

              {/* Live Demo Box */}
              <div className="mt-8 bg-white/5 backdrop-blur-sm border border-white/20 p-6 rounded-xl shadow-lg">
                <h3 className="font-semibold mb-2">Live Demo</h3>
                <p className="text-sm text-slate-300">
                  Run a simulation to enqueue a percentage of tiles. The map shows
                  freshly updated tiles in green and stale tiles in red, illustrating
                  how JVT regenerates only the affected areas.
                </p>
              </div>
            </div>
          </div>

          {/* ──────────────────── Right Side – Live Dashboard ───────────────────── */}
          <div className="bg-white/5 backdrop-blur-lg rounded-2xl p-6 text-white shadow-2xl border border-white/20">
            {/* Header */}
            <div className="mb-6">
              <h3 className="text-xl font-semibold bg-gradient-to-r from-cyan-200 to-fuchsia-300 bg-clip-text text-transparent mb-2">
                Live Performance Monitor
              </h3>
              <p className="text-slate-300 text-sm">
                Real-time tile generation efficiency
              </p>
            </div>

            {/* Top metrics – focused on three stats: Speed, Data size, Savings */}
            <div className="grid grid-cols-3 gap-4 mb-6">
              {/* Speed */}
              <div className="bg-white/10 backdrop-blur-sm border border-cyan-300/20 rounded-xl p-4">
                <div className="text-xs uppercase tracking-wide text-cyan-200 mb-1">Speed</div>
                <div className="text-2xl font-bold text-white">{speedProcessedLabel}</div>
                <div className="text-[11px] text-slate-300 mt-1">Full run: {speedFullLabel}</div>
              </div>
              {/* Data size */}
              <div className="bg-white/10 backdrop-blur-sm border border-fuchsia-300/20 rounded-xl p-4">
                <div className="text-xs uppercase tracking-wide text-fuchsia-200 mb-1">Data size</div>
                <div className="text-2xl font-bold text-white">{sizeProcessedLabel}</div>
                <div className="text-[11px] text-slate-300 mt-1">Full run: {sizeFullLabel}</div>
              </div>
              {/* Savings */}
              <div className="bg-white/10 backdrop-blur-sm border border-emerald-300/20 rounded-xl p-4">
                <div className="text-xs uppercase tracking-wide text-emerald-200 mb-1">Savings</div>
                <div className="text-2xl font-bold text-emerald-300">{cacheHitPct.toFixed(1)}%</div>
                <div className="text-[11px] text-slate-300 mt-1">Tiles skipped: {tilesSkipped}</div>
              </div>
            </div>

            {/* Simulation Controls */}
            <div className="bg-white/10 backdrop-blur-sm border border-white/20 rounded-xl p-4 mb-6">
              <div className="text-sm font-medium text-white mb-3">
                Interactive Tile Simulation
              </div>

              <div className="space-y-4">
                {/* Percentage Slider */}
                <div>
                  <div className="flex justify-between items-center mb-2">
                    <label className="text-xs text-slate-300">
                      Regeneration Percentage
                    </label>
                    <span className="text-sm font-medium text-white">
                      {simulationPercentage.toFixed(1)}%
                    </span>
                  </div>
                  <input
                    type="range"
                    min="1"
                    max="100"
                    step="0.5"
                    value={simulationPercentage}
                    onChange={(e) => setSimulationPercentage(parseFloat(e.target.value))}
                    className="w-full h-2 bg-white/20 rounded-lg appearance-none cursor-pointer slider"
                    disabled={isSimulating}
                  />
                </div>

                {/* Run Button */}
                <button
                  onClick={runSimulation}
                  disabled={isSimulating}
                  className={`w-full py-2 px-4 rounded-lg font-medium text-sm transition-all ${isSimulating
                    ? 'bg-gray-600 text-gray-400 cursor-not-allowed'
                    : 'bg-gradient-to-r from-cyan-500 to-fuchsia-500 text-white hover:from-cyan-400 hover:to-fuchsia-400'
                    }`}
                >
                  {isSimulating ? 'Processing...' : 'Run Simulation'}
                </button>

                {/* Simulation Progress Indicator */}
                {isSimulating && simulationStatus?.active_sessions && simulationStatus.active_sessions.length > 0 && (
                  <div className="mt-3 p-3 bg-white/10 backdrop-blur-sm border border-cyan-300/20 rounded-lg">
                    <div className="flex justify-between items-center mb-2">
                      <span className="text-xs text-cyan-200">Simulation Progress</span>
                      <span className="text-xs text-white">
                        {simulationStatus?.active_sessions[0]?.percentage?.toFixed(1)}%
                      </span>
                    </div>
                    <div className="w-full bg-white/20 rounded-full h-2">
                      <div 
                        className="bg-gradient-to-r from-cyan-500 to-fuchsia-500 h-2 rounded-full transition-all duration-300"
                        style={{ width: `${simulationStatus?.active_sessions[0]?.percentage || 0}%` }}
                      />
                    </div>
                    <div className="text-xs text-slate-300 mt-1">
                      Status: {simulationStatus?.active_sessions[0]?.status || 'Unknown'}
                    </div>
                  </div>
                )}
              </div>
            </div>

            {/* Map preview */}
            <div className="bg-white/10 backdrop-blur-sm border border-white/20 rounded-xl p-4 mb-6">
              <div className="flex justify-between items-center mb-3">
                <div className="text-sm font-medium text-white">
                  Tile Status Visualization
                </div>
                <div className="text-xs text-slate-300">
                  <span className="text-emerald-300">
                    {tileStatus?.fresh_count || 0} fresh
                  </span>{' '}
                  •
                  <span className="text-rose-300">
                    {' '}
                    {tileStatus?.stale_count || 0} stale
                  </span>
                </div>
              </div>
              <div className="h-80 w-full rounded-lg overflow-hidden border border-white/10">
                <Map 
                  refreshTrigger={mapRefreshTrigger} 
                  simulationBounds={lastSimulationBounds}
                  autoZoomTrigger={autoZoomTrigger}
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

export default App
