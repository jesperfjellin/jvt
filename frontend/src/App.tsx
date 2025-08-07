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

  const formatTime = (freshCount: number) => {
    const estimatedTime = Math.max(0.1, freshCount * 0.0006)
    return estimatedTime < 1
      ? `${(estimatedTime * 1000).toFixed(0)} ms`
      : `${estimatedTime.toFixed(1)} s`
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

  const { timeRatio } = getEfficiencyRatio()
  const processingTime = tileStatus ? formatTime(tileStatus.fresh_count) : '—'

  const runSimulation = async () => {
    setIsSimulating(true)
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
                Incremental Vector Tiles
              </h1>
              <p className="text-xl leading-relaxed mb-2">
                A smarter way to render and deliver map tiles by processing only
                the changes, not rebuilding everything from scratch.
              </p>
            </div>

            <div className="flex-1 space-y-6">
              {/* How it works */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">How it works</h2>
                <p className="leading-relaxed">
                  Traditional tile generation rebuilds the entire tileset
                  whenever data changes. JVT uses PostgreSQL triggers and
                  LISTEN/NOTIFY to detect exactly which tiles need updates, then
                  regenerates only those specific tiles.
                </p>
              </div>

              {/* Tech stack */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">
                  The technology stack
                </h2>
                <ul className="space-y-2">
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>PostGIS:</strong> Spatial database with change
                      detection triggers
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>Rust:</strong> High-performance tile generation
                      with zero-copy streaming
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>MVT:</strong> Mapbox Vector Tiles for efficient
                      geometry encoding
                    </span>
                  </li>
                  <li className="flex items-center space-x-2">
                    <span className="w-2 h-2 bg-gradient-to-r from-rose-400 to-fuchsia-400 rounded-full" />
                    <span>
                      <strong>PMTiles:</strong> Incremental archive format for
                      efficient storage
                    </span>
                  </li>
                </ul>
              </div>

              {/* Why it matters */}
              <div>
                <h2 className="text-2xl font-semibold mb-5">Why it matters</h2>
                <p className="leading-relaxed">
                  For large-scale mapping applications, regenerating millions of
                  tiles for small changes wastes computational resources and
                  increases latency. JVT enables near-real-time map updates
                  while dramatically reducing processing overhead.
                </p>
              </div>

              {/* Live Demo Box */}
              <div className="mt-8 bg-white/5 backdrop-blur-sm border border-white/20 p-6 rounded-xl shadow-lg">
                <h3 className="font-semibold mb-2">Live Demo</h3>
                <p className="text-sm text-slate-300">
                  The dashboard on the right shows a live simulation with
                  synthetic data changes every 5 minutes. Green tiles are
                  freshly regenerated, red tiles contain stale data. This
                  demonstrates JVT’s ability to selectively update only changed
                  areas.
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

            {/* Top metrics */}
            <div className="grid grid-cols-3 gap-4 mb-6">
              <div className="bg-white/10 backdrop-blur-sm border border-cyan-300/20 rounded-xl p-4 text-center">
                <div className="text-2xl font-bold bg-gradient-to-r from-cyan-300 to-cyan-100 bg-clip-text text-transparent">
                  {timeRatio}x
                </div>
                <div className="text-slate-300 text-sm">faster processing</div>
              </div>
              <div className="bg-white/10 backdrop-blur-sm border border-fuchsia-300/20 rounded-xl p-4 text-center">
                <div className="text-2xl font-bold text-white">
                  {tileStatus?.fresh_count || 0}
                </div>
                <div className="text-slate-300 text-sm">tiles updated</div>
              </div>
              <div className="bg-white/10 backdrop-blur-sm border border-white/20 rounded-xl p-4 text-center">
                <div className="text-2xl font-bold text-white">
                  {processingTime}
                </div>
                <div className="text-slate-300 text-sm">processing time</div>
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

            {/* Technical stats */}
            <div className="grid grid-cols-2 gap-4 text-xs">
              <div className="bg-white/10 backdrop-blur-sm border border-cyan-300/20 rounded-lg p-3">
                <div className="text-cyan-200">Engine</div>
                <div className="font-medium text-white">Rust + PostGIS</div>
              </div>
              <div className="bg-white/10 backdrop-blur-sm border border-fuchsia-300/20 rounded-lg p-3">
                <div className="text-fuchsia-200">Update Cycle</div>
                <div className="font-medium text-white">5 minutes</div>
              </div>
              <div className="bg-white/10 backdrop-blur-sm border border-white/20 rounded-lg p-3">
                <div className="text-slate-300">Total Tiles</div>
                <div className="font-medium text-white">
                  {(tileStatus?.fresh_count || 0) +
                    (tileStatus?.stale_count || 0)}
                </div>
              </div>
              <div className="bg-white/10 backdrop-blur-sm border border-emerald-300/20 rounded-lg p-3">
                <div className="text-emerald-200">Efficiency</div>
                <div className="font-medium text-emerald-300">
                  {tileStatus &&
                    tileStatus.fresh_count + tileStatus.stale_count > 0
                    ? `${(
                      (tileStatus.stale_count /
                        (tileStatus.fresh_count + tileStatus.stale_count)) *
                      100
                    ).toFixed(1)}%`
                    : '0%'}{' '}
                  cache hit
                </div>
              </div>
            </div>
          </div>
          {/* ────────────────────────────────────────────────────────────────────── */}
        </div>
      </div>
    </div>
  )
}

export default App
