import React, { useEffect, useRef, useState, useCallback } from 'react'
import './TileActivityDashboard.css'

interface TileStatus {
  z: number;
  x: number;
  y: number;
  last_updated: string | null;
  is_fresh: boolean;
  change_count: number;
  seconds_since_update: number | null;
}

interface PerformanceStats {
  tiles_updated: number;
  estimated_processing_time_ms: number;
  full_regeneration_time_ms: number;
  speedup_factor: number;
  efficiency_percentage: number;
}

interface TileStatusResponse {
  tiles: TileStatus[];
  fresh_count: number;
  stale_count: number;
  last_check: string;
  performance_stats: PerformanceStats;
}

interface TileActivity {
  x: number;
  y: number;
  changeCount: number;
  isFresh: boolean;
  secondsSinceUpdate: number | null;
}

const TileActivityDashboard: React.FC = () => {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const animationRef = useRef<number>()
  const [tileStatus, setTileStatus] = useState<TileStatusResponse | null>(null)
  const [tileActivities, setTileActivities] = useState<TileActivity[]>([])
  const [animationTime, setAnimationTime] = useState(0)

  // Fetch tile status from API
  const fetchTileStatus = async () => {
    try {
      const response = await fetch('http://localhost:8080/api/tile-status')
      if (response.ok) {
        const data: TileStatusResponse = await response.json()
        setTileStatus(data)
        
        // Process tiles into simplified grid (group into 32x32 regions)
        const activities = processTilesIntoActivities(data.tiles)
        setTileActivities(activities)
        
        console.log(`Fetched tile status: ${data.fresh_count} fresh, speedup: ${data.performance_stats.speedup_factor.toFixed(1)}x`)
      } else {
        console.error('Failed to fetch tile status:', response.status)
      }
    } catch (error) {
      console.error('Error fetching tile status:', error)
    }
  }

  // Group 256x256 tiles into 32x32 regions for visualization
  const processTilesIntoActivities = (tiles: TileStatus[]): TileActivity[] => {
    const regionSize = 8 // 256/32 = 8 tiles per region
    const activities = new Map<string, TileActivity>()

    tiles.forEach(tile => {
      const regionX = Math.floor(tile.x / regionSize)
      const regionY = Math.floor(tile.y / regionSize)
      const key = `${regionX},${regionY}`

      const existing = activities.get(key)
      if (existing) {
        existing.changeCount += tile.change_count
        existing.isFresh = existing.isFresh || tile.is_fresh
        if (tile.seconds_since_update !== null) {
          existing.secondsSinceUpdate = Math.min(
            existing.secondsSinceUpdate || Infinity,
            tile.seconds_since_update
          )
        }
      } else {
        activities.set(key, {
          x: regionX,
          y: regionY,
          changeCount: tile.change_count,
          isFresh: tile.is_fresh,
          secondsSinceUpdate: tile.seconds_since_update
        })
      }
    })

    return Array.from(activities.values())
  }

  // Animation loop
  const animate = useCallback(() => {
    setAnimationTime(prev => prev + 0.016) // ~60fps
    animationRef.current = requestAnimationFrame(animate)
  }, [])

  // Draw the activity visualization
  const drawActivity = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !tileActivities.length) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const { width, height } = canvas
    const gridSize = 32
    const cellSize = Math.min(width, height) / gridSize

    // Clear canvas with dark background
    ctx.fillStyle = '#0a0a0a'
    ctx.fillRect(0, 0, width, height)

    // Draw grid background (subtle)
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)'
    ctx.lineWidth = 0.5
    for (let i = 0; i <= gridSize; i++) {
      const pos = i * cellSize
      ctx.beginPath()
      ctx.moveTo(pos, 0)
      ctx.lineTo(pos, gridSize * cellSize)
      ctx.stroke()
      
      ctx.beginPath()
      ctx.moveTo(0, pos)
      ctx.lineTo(gridSize * cellSize, pos)
      ctx.stroke()
    }

    // Draw activity bubbles
    tileActivities.forEach(activity => {
      if (activity.changeCount === 0) return

      const x = activity.x * cellSize + cellSize / 2
      const y = activity.y * cellSize + cellSize / 2

      // Calculate bubble properties
      const maxChanges = Math.max(...tileActivities.map(a => a.changeCount))
      const normalizedSize = Math.min(1, activity.changeCount / Math.max(1, maxChanges))
      const baseRadius = cellSize * 0.15
      const maxRadius = cellSize * 0.4
      
      // Animate fresh tiles with pulsing effect
      let radius = baseRadius + (maxRadius - baseRadius) * normalizedSize
      if (activity.isFresh) {
        const pulse = 1 + 0.3 * Math.sin(animationTime * 3)
        radius *= pulse
      }

      // Color based on freshness and age
      let color: string
      if (activity.isFresh) {
        const intensity = 0.5 + 0.5 * normalizedSize
        color = `rgba(16, 185, 129, ${intensity})` // Green
      } else {
        const age = activity.secondsSinceUpdate || 300
        const ageIntensity = Math.max(0.2, 1 - (age / 600)) // Fade over 10 minutes
        const intensity = 0.3 + 0.4 * ageIntensity
        color = `rgba(239, 68, 68, ${intensity})` // Red
      }

      // Draw bubble with glow effect
      ctx.save()
      
      // Outer glow
      if (activity.isFresh) {
        const gradient = ctx.createRadialGradient(x, y, 0, x, y, radius * 2)
        gradient.addColorStop(0, color)
        gradient.addColorStop(1, 'rgba(16, 185, 129, 0)')
        ctx.fillStyle = gradient
        ctx.beginPath()
        ctx.arc(x, y, radius * 2, 0, Math.PI * 2)
        ctx.fill()
      }

      // Main bubble
      ctx.fillStyle = color
      ctx.beginPath()
      ctx.arc(x, y, radius, 0, Math.PI * 2)
      ctx.fill()

      // Inner highlight
      ctx.fillStyle = `rgba(255, 255, 255, 0.3)`
      ctx.beginPath()
      ctx.arc(x - radius * 0.3, y - radius * 0.3, radius * 0.3, 0, Math.PI * 2)
      ctx.fill()

      ctx.restore()

      // Draw change count for significant activities
      if (activity.changeCount > 5) {
        ctx.fillStyle = 'white'
        ctx.font = `${Math.max(8, cellSize * 0.15)}px sans-serif`
        ctx.textAlign = 'center'
        ctx.textBaseline = 'middle'
        ctx.fillText(activity.changeCount.toString(), x, y)
      }
    })
  }, [tileActivities, animationTime])

  // Set up canvas and animation
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const resizeCanvas = () => {
      const container = canvas.parentElement
      if (container) {
        const size = Math.min(container.clientWidth, container.clientHeight)
        canvas.width = size
        canvas.height = size
        canvas.style.width = `${size}px`
        canvas.style.height = `${size}px`
      }
    }

    resizeCanvas()
    window.addEventListener('resize', resizeCanvas)

    // Start animation
    animate()

    return () => {
      window.removeEventListener('resize', resizeCanvas)
      if (animationRef.current) {
        cancelAnimationFrame(animationRef.current)
      }
    }
  }, [animate])

  // Draw when data changes
  useEffect(() => {
    drawActivity()
  }, [drawActivity])

  // Fetch initial data and set up polling
  useEffect(() => {
    fetchTileStatus()
    const interval = setInterval(fetchTileStatus, 15000)
    return () => clearInterval(interval)
  }, [])

  const formatTime = (ms: number): string => {
    if (ms < 1000) return `${ms}ms`
    return `${(ms / 1000).toFixed(1)}s`
  }

  const formatSpeedup = (factor: number): string => {
    return `${factor.toFixed(1)}x faster`
  }

  return (
    <div className="tile-activity-dashboard">
      {/* Main Activity Visualization */}
      <div className="activity-canvas-container">
        <canvas ref={canvasRef} className="activity-canvas" />
        
        {/* Overlay Info */}
        <div className="activity-overlay">
          <div className="activity-legend">
            <div className="legend-item">
              <div className="legend-dot fresh"></div>
              <span>Active (fresh updates)</span>
            </div>
            <div className="legend-item">
              <div className="legend-dot stale"></div>
              <span>Aging (stale data)</span>
            </div>
          </div>
        </div>
      </div>

      {/* Performance Stats */}
      {tileStatus && (
        <div className="performance-stats">
          <div className="stat-row primary">
            <div className="stat-label">Updated</div>
            <div className="stat-value">{tileStatus.performance_stats.tiles_updated} tiles</div>
          </div>
          
          <div className="stat-row">
            <div className="stat-label">Processing Time</div>
            <div className="stat-value">{formatTime(tileStatus.performance_stats.estimated_processing_time_ms)}</div>
          </div>
          
          <div className="stat-row">
            <div className="stat-label">vs Full Regeneration</div>
            <div className="stat-value">{formatTime(tileStatus.performance_stats.full_regeneration_time_ms)}</div>
          </div>
          
          <div className="stat-row highlight">
            <div className="stat-label">Efficiency Gain</div>
            <div className="stat-value speedup">{formatSpeedup(tileStatus.performance_stats.speedup_factor)}</div>
          </div>
        </div>
      )}
    </div>
  )
}

export default TileActivityDashboard