import React, { useEffect, useRef, useState } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import './Map.css'

interface TileStatus {
  z: number;
  x: number;
  y: number;
  last_updated: string | null;
  is_fresh: boolean;
}

interface TileStatusResponse {
  tiles: TileStatus[];
  fresh_count: number;
  stale_count: number;
  last_check: string;
}

interface MapProps {
  refreshTrigger?: number; // Used to trigger refresh from parent
  simulationBounds?: {
    bbox_min_x: number
    bbox_min_y: number
    bbox_max_x: number
    bbox_max_y: number
  } | null;
  autoZoomTrigger?: number; // Used to trigger auto-zoom
}

const Map: React.FC<MapProps> = ({ refreshTrigger, simulationBounds, autoZoomTrigger }) => {
  const mapContainer = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)
  const [tileStatus, setTileStatus] = useState<TileStatusResponse | null>(null)
  const [isAutoZooming, setIsAutoZooming] = useState(false)

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

  // Convert tile coordinates to geographic bounds
  const tileToLatLng = (z: number, x: number, y: number) => {
    const n = Math.pow(2, z)
    const lon = (x / n) * 360 - 180
    const lat = Math.atan(Math.sinh(Math.PI * (1 - (2 * y) / n))) * (180 / Math.PI)
    return { lon, lat }
  }

  // Convert tile coordinates to GeoJSON polygon
  const tileToGeoJSON = (tile: TileStatus) => {
    // Calculate tile bounds using standard web mercator projection
    const n = Math.pow(2, tile.z)
    const lon1 = (tile.x / n) * 360 - 180
    const lat1 = Math.atan(Math.sinh(Math.PI * (1 - (2 * tile.y) / n))) * (180 / Math.PI)
    const lon2 = ((tile.x + 1) / n) * 360 - 180
    const lat2 = Math.atan(Math.sinh(Math.PI * (1 - (2 * (tile.y + 1)) / n))) * (180 / Math.PI)

    return {
      type: 'Feature' as const,
      geometry: {
        type: 'Polygon' as const,
        coordinates: [[
          [lon1, lat1],
          [lon2, lat1],
          [lon2, lat2],
          [lon1, lat2],
          [lon1, lat1]
        ]]
      },
      properties: {
        z: tile.z,
        x: tile.x,
        y: tile.y,
        is_fresh: tile.is_fresh,
        last_updated: tile.last_updated
      }
    }
  }

  // Auto-zoom to simulation bounds
  const zoomToSimulationBounds = (map: maplibregl.Map, bounds: NonNullable<typeof simulationBounds>) => {
    setIsAutoZooming(true)
    
    // Convert tile coordinates to geographic bounds
    // Assuming zoom level 8 based on the system configuration
    const zoom = 8
    
    const topLeft = tileToLatLng(zoom, bounds.bbox_min_x, bounds.bbox_min_y)
    const bottomRight = tileToLatLng(zoom, bounds.bbox_max_x + 1, bounds.bbox_max_y + 1)

    // Clamp to valid WebMercator extent and avoid exact world edges (can confuse fitBounds
    // when renderWorldCopies is disabled)
    const clamp = (lon: number, lat: number) => {
      const clampedLon = Math.max(-179.999, Math.min(179.999, lon))
      const clampedLat = Math.max(-85.051, Math.min(85.051, lat))
      return [clampedLon, clampedLat] as [number, number]
    }
    
    // Create bounds object for MapLibre
    const sw = clamp(topLeft.lon, bottomRight.lat)
    const ne = clamp(bottomRight.lon, topLeft.lat)
    const mapBounds = new maplibregl.LngLatBounds(sw, ne)
    
    console.log('Auto-zooming to simulation bounds:', {
      tiles: `(${bounds.bbox_min_x},${bounds.bbox_min_y}) to (${bounds.bbox_max_x},${bounds.bbox_max_y})`,
      geographic: `(${topLeft.lon.toFixed(4)},${bottomRight.lat.toFixed(4)}) to (${bottomRight.lon.toFixed(4)},${topLeft.lat.toFixed(4)})`
    })
    
    // Fit the map to the bounds with some padding
    map.fitBounds(mapBounds, {
      padding: 20,
      duration: 1000, // 1 second animation
      essential: true
    })
    
    // Clear the auto-zoom indicator after animation completes
    setTimeout(() => {
      setIsAutoZooming(false)
    }, 1200)
  }

  // Update map with tile overlay
  const updateTileOverlay = (map: maplibregl.Map) => {
    if (!tileStatus) return

    const geojson = {
      type: 'FeatureCollection' as const,
      features: tileStatus.tiles.map(tileToGeoJSON)
    }

    // Update or add the tile overlay source 
    if (map.getSource('tile-overlay')) {
      (map.getSource('tile-overlay') as maplibregl.GeoJSONSource).setData(geojson)
    } else {
      map.addSource('tile-overlay', {
        type: 'geojson',
        data: geojson
      })

      // Add fill layer for tiles
      map.addLayer({
        id: 'tile-fill',
        type: 'fill',
        source: 'tile-overlay',
        paint: {
          'fill-color': [
            'case',
            ['get', 'is_fresh'],
            '#00ff00', // Green for fresh tiles
            '#ff0000'  // Red for stale tiles
          ],
          'fill-opacity': 0.3
        }
      })


    }
  }

  useEffect(() => {
    if (!mapContainer.current) return

    // Initialize the map
    mapRef.current = new maplibregl.Map({
      container: mapContainer.current,
      style: {
        version: 8,
        sources: {
          'raster-tiles': {
            type: 'raster',
            tiles: [
              'https://tile.openstreetmap.org/{z}/{x}/{y}.png'
            ],
            tileSize: 256,
            minzoom: 0,
            maxzoom: 19,
            attribution: '© OpenStreetMap contributors'
          }
        },
        layers: [
          {
            id: 'background',
            type: 'background',
            paint: {
              'background-color': '#f0f0f0'
            }
          },
          {
            id: 'raster-layer',
            type: 'raster',
            source: 'raster-tiles',
            paint: {}
          }
        ]
      },
      center: [0, 0],
      zoom: 2,
      minZoom: 0,
      maxZoom: 19,
      bearing: 0,
      pitch: 0,
      // Show a single world only (no repeating continents)
      renderWorldCopies: false,
      // Leave panning unconstrained to avoid odd edge-fitting effects; we still
      // clamp bounds during fit to stay within WebMercator range.
    })

    // Add navigation controls
    mapRef.current.addControl(new maplibregl.NavigationControl(), 'top-right')

    // Map event handlers
    mapRef.current.on('load', () => {
      console.log('Map loaded successfully')
      // Fetch initial tile status
      fetchTileStatus()
      // Ensure the map has correct size after initial layout
      mapRef.current?.resize()
    })

    mapRef.current.on('error', (e: any) => {
      console.error('Map error:', e)
    })

    // Proactively ensure container has non-zero size before first render
    const ensureSized = () => {
      const el = mapContainer.current
      if (!el) return
      const w = el.clientWidth
      const h = el.clientHeight
      if (w === 0 || h === 0) {
        requestAnimationFrame(ensureSized)
      } else {
        mapRef.current?.resize()
      }
    }
    ensureSized()

    // Also resize on window resizes
    const onWindowResize = () => mapRef.current?.resize()
    window.addEventListener('resize', onWindowResize)

    // Cleanup function
    return () => {
      if (mapRef.current) {
        mapRef.current.remove()
      }
      window.removeEventListener('resize', onWindowResize)
    }
  }, [])

  // Update tile overlay when tile status changes
  useEffect(() => {
    if (mapRef.current && tileStatus && mapRef.current.isStyleLoaded()) {
      updateTileOverlay(mapRef.current)
    }
  }, [tileStatus])

  // Refresh when parent triggers it
  useEffect(() => {
    if (refreshTrigger && refreshTrigger > 0) {
      fetchTileStatus()
    }
  }, [refreshTrigger])

  // Auto-zoom when explicitly triggered
  useEffect(() => {
    if (!simulationBounds || !autoZoomTrigger || autoZoomTrigger <= 0) return
    const map = mapRef.current
    if (!map) return

    const run = () => {
      // Small delay to ensure tile overlay is updated first
      setTimeout(() => {
        if (mapRef.current) {
          zoomToSimulationBounds(mapRef.current, simulationBounds)
        }
      }, 300)
    }

    if (map.isStyleLoaded()) {
      run()
    } else {
      const onLoad = () => {
        run()
        map.off('load', onLoad)
      }
      map.on('load', onLoad)
    }
  }, [autoZoomTrigger, simulationBounds])

  return (
    <div className="map-component relative">
      <div ref={mapContainer} className="map" />
    </div>
  )
}

export default Map 