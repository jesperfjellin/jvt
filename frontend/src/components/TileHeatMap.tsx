import React, { useEffect, useRef, useState, useCallback } from 'react'
import './TileHeatMap.css'

interface TileStatus {
  z: number;
  x: number;
  y: number;
  last_updated: string | null;
  is_fresh: boolean;
  change_count: number;
  seconds_since_update: number | null;
}

interface TileStatusResponse {
  tiles: TileStatus[];
  fresh_count: number;
  stale_count: number;
  last_check: string;
}

interface HoveredTile {
  x: number;
  y: number;
  tile: TileStatus;
  screenX: number;
  screenY: number;
}

const TileHeatMap: React.FC = () => {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const [tileStatus, setTileStatus] = useState<TileStatusResponse | null>(null)
  const [hoveredTile, setHoveredTile] = useState<HoveredTile | null>(null)
  const [canvasSize, setCanvasSize] = useState({ width: 400, height: 400 })

  // Fetch tile status from API
  const fetchTileStatus = async () => {
    try {
      const response = await fetch('http://localhost:8080/api/tile-status')
      if (response.ok) {
        const data: TileStatusResponse = await response.json()
        setTileStatus(data)
        console.log(`Fetched tile status: ${data.fresh_count} fresh, ${data.stale_count} stale`)
      } else {
        console.error('Failed to fetch tile status:', response.status)
      }
    } catch (error) {
      console.error('Error fetching tile status:', error)
    }
  }

  // Calculate heat map color based on tile status
  const getTileColor = (tile: TileStatus): string => {
    if (!tile.is_fresh && tile.change_count === 0) {
      // Never processed - dark gray
      return '#1a1a1a'
    }

    if (!tile.is_fresh) {
      // Stale - fade from red to dark red based on age
      const maxAge = 600 // 10 minutes
      const age = tile.seconds_since_update || maxAge
      const intensity = Math.max(0.2, 1 - (age / maxAge))
      const red = Math.floor(120 + (135 * intensity)) // 120-255
      return `rgb(${red}, 40, 40)`
    }

    // Fresh - intensity based on change count
    const maxChanges = 10 // Assume max 10 changes for scaling
    const intensity = Math.min(1, tile.change_count / maxChanges)
    const green = Math.floor(100 + (155 * intensity)) // 100-255
    const blue = Math.floor(50 + (100 * intensity))   // 50-150
    return `rgb(40, ${green}, ${blue})`
  }

  // Draw the heat map
  const drawHeatMap = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !tileStatus) return

    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const { width, height } = canvasSize
    const tileSize = Math.min(width, height) / 256 // 256x256 grid for z8

    // Clear canvas
    ctx.fillStyle = '#0a0a0a'
    ctx.fillRect(0, 0, width, height)

    // Create a map for quick tile lookup
    const tileMap = new Map<string, TileStatus>()
    tileStatus.tiles.forEach(tile => {
      tileMap.set(`${tile.x},${tile.y}`, tile)
    })

    // Draw tiles
    for (let x = 0; x < 256; x++) {
      for (let y = 0; y < 256; y++) {
        const tile = tileMap.get(`${x},${y}`)
        if (tile) {
          ctx.fillStyle = getTileColor(tile)
          ctx.fillRect(
            x * tileSize,
            y * tileSize,
            Math.ceil(tileSize),
            Math.ceil(tileSize)
          )
        }
      }
    }

    // Draw grid lines (subtle)
    if (tileSize > 2) {
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.1)'
      ctx.lineWidth = 0.5
      
      // Vertical lines
      for (let x = 0; x <= 256; x += 16) { // Every 16th line
        ctx.beginPath()
        ctx.moveTo(x * tileSize, 0)
        ctx.lineTo(x * tileSize, 256 * tileSize)
        ctx.stroke()
      }
      
      // Horizontal lines
      for (let y = 0; y <= 256; y += 16) { // Every 16th line
        ctx.beginPath()
        ctx.moveTo(0, y * tileSize)
        ctx.lineTo(256 * tileSize, y * tileSize)
        ctx.stroke()
      }
    }
  }, [tileStatus, canvasSize])

  // Handle mouse move for hover effects
  const handleMouseMove = (event: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current
    if (!canvas || !tileStatus) return

    const rect = canvas.getBoundingClientRect()
    const mouseX = event.clientX - rect.left
    const mouseY = event.clientY - rect.top

    const tileSize = Math.min(canvasSize.width, canvasSize.height) / 256
    const tileX = Math.floor(mouseX / tileSize)
    const tileY = Math.floor(mouseY / tileSize)

    if (tileX >= 0 && tileX < 256 && tileY >= 0 && tileY < 256) {
      const tile = tileStatus.tiles.find(t => t.x === tileX && t.y === tileY)
      if (tile) {
        setHoveredTile({
          x: tileX,
          y: tileY,
          tile,
          screenX: event.clientX,
          screenY: event.clientY
        })
      } else {
        setHoveredTile(null)
      }
    } else {
      setHoveredTile(null)
    }
  }

  const handleMouseLeave = () => {
    setHoveredTile(null)
  }

  // Update canvas size based on container
  useEffect(() => {
    const updateSize = () => {
      if (containerRef.current) {
        const { clientWidth, clientHeight } = containerRef.current
        const size = Math.min(clientWidth, clientHeight)
        setCanvasSize({ width: size, height: size })
      }
    }

    updateSize()
    window.addEventListener('resize', updateSize)
    return () => window.removeEventListener('resize', updateSize)
  }, [])

  // Set canvas resolution
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return

    const { width, height } = canvasSize
    const dpr = window.devicePixelRatio || 1

    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`

    const ctx = canvas.getContext('2d')
    if (ctx) {
      ctx.scale(dpr, dpr)
    }
  }, [canvasSize])

  // Draw heat map when data changes
  useEffect(() => {
    drawHeatMap()
  }, [drawHeatMap])

  // Fetch initial data and set up polling
  useEffect(() => {
    fetchTileStatus()
    const interval = setInterval(fetchTileStatus, 15000) // Update every 15 seconds
    return () => clearInterval(interval)
  }, [])

  const formatLastUpdated = (lastUpdated: string | null): string => {
    if (!lastUpdated) return 'Never'
    const date = new Date(lastUpdated)
    const now = new Date()
    const diffMs = now.getTime() - date.getTime()
    const diffMins = Math.floor(diffMs / 60000)
    
    if (diffMins < 1) return 'Just now'
    if (diffMins < 60) return `${diffMins}m ago`
    const diffHours = Math.floor(diffMins / 60)
    return `${diffHours}h ago`
  }

  return (
    <div ref={containerRef} className="tile-heatmap-container">
      <canvas
        ref={canvasRef}
        className="tile-heatmap-canvas"
        onMouseMove={handleMouseMove}
        onMouseLeave={handleMouseLeave}
      />
      
      {/* Tooltip */}
      {hoveredTile && (
        <div 
          className="tile-tooltip"
          style={{
            left: hoveredTile.screenX + 10,
            top: hoveredTile.screenY - 10,
          }}
        >
          <div className="tooltip-header">
            Tile {hoveredTile.x}, {hoveredTile.y}
          </div>
          <div className="tooltip-content">
            <div>Status: <span className={hoveredTile.tile.is_fresh ? 'fresh' : 'stale'}>
              {hoveredTile.tile.is_fresh ? 'Fresh' : 'Stale'}
            </span></div>
            <div>Changes: {hoveredTile.tile.change_count}</div>
            <div>Last updated: {formatLastUpdated(hoveredTile.tile.last_updated)}</div>
            {hoveredTile.tile.seconds_since_update && (
              <div>Age: {Math.floor(hoveredTile.tile.seconds_since_update)}s</div>
            )}
          </div>
        </div>
      )}

      {/* Legend */}
      <div className="heatmap-legend">
        <div className="legend-item">
          <div className="legend-color fresh"></div>
          <span>Fresh (recently updated)</span>
        </div>
        <div className="legend-item">
          <div className="legend-color stale"></div>
          <span>Stale (needs update)</span>
        </div>
        <div className="legend-item">
          <div className="legend-color never"></div>
          <span>Never processed</span>
        </div>
      </div>
    </div>
  )
}

export default TileHeatMap