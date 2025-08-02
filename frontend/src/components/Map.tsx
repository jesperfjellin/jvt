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

const Map: React.FC = () => {
  const mapContainer = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)
  const [tileStatus, setTileStatus] = useState<TileStatusResponse | null>(null)
  const [loading, setLoading] = useState(true)

  // Fetch tile status from API
  const fetchTileStatus = async () => {
    try {
      const response = await fetch('http://localhost:8080/api/tile-status')
      if (response.ok) {
        const data: TileStatusResponse = await response.json()
        setTileStatus(data)
        setLoading(false)
        console.log(`Fetched tile status: ${data.fresh_count} fresh, ${data.stale_count} stale`)
      } else {
        console.error('Failed to fetch tile status:', response.status)
      }
    } catch (error) {
      console.error('Error fetching tile status:', error)
    }
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

      // Add border layer for tiles
      map.addLayer({
        id: 'tile-border',
        type: 'line',
        source: 'tile-overlay',
        paint: {
          'line-color': '#ffffff',
          'line-width': 1,
          'line-opacity': 0.8
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
      center: [10.75, 59.95], // Oslo, Norway
      zoom: 10,
      bearing: 0,
      pitch: 0
    })

    // Add navigation controls
    mapRef.current.addControl(new maplibregl.NavigationControl(), 'top-right')

    // Add scale control
    mapRef.current.addControl(new maplibregl.ScaleControl(), 'bottom-left')

    // Map event handlers
    mapRef.current.on('load', () => {
      console.log('Map loaded successfully')
      // Fetch initial tile status
      fetchTileStatus()
    })

    mapRef.current.on('error', (e) => {
      console.error('Map error:', e)
    })

    // Cleanup function
    return () => {
      if (mapRef.current) {
        mapRef.current.remove()
      }
    }
  }, [])

  // Update tile overlay when tile status changes
  useEffect(() => {
    if (mapRef.current && tileStatus && mapRef.current.isStyleLoaded()) {
      updateTileOverlay(mapRef.current)
    }
  }, [tileStatus])

  // Set up periodic tile status updates
  useEffect(() => {
    const interval = setInterval(fetchTileStatus, 30000) // Update every 30 seconds
    return () => clearInterval(interval)
  }, [])

  return (
    <div className="map-container">
      <div ref={mapContainer} className="map" />
      <div className="map-overlay">
        <div className="map-info">
          <p><strong>JVT Tile Status</strong></p>
          {loading ? (
            <p>Loading tile status...</p>
          ) : tileStatus ? (
            <>
              <p><strong>Fresh:</strong> <span style={{color: '#00aa00'}}>{tileStatus.fresh_count} tiles</span></p>
              <p><strong>Stale:</strong> <span style={{color: '#aa0000'}}>{tileStatus.stale_count} tiles</span></p>
              <p><strong>Last Check:</strong> {new Date(tileStatus.last_check).toLocaleTimeString()}</p>
              <p style={{fontSize: '0.8rem', opacity: 0.8}}>
                Green = Updated &lt;5min ago<br/>
                Red = Older than 5min
              </p>
            </>
          ) : (
            <p>No tile data available</p>
          )}
        </div>
      </div>
    </div>
  )
}

export default Map 