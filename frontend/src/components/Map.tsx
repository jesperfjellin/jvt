import React, { useEffect, useRef } from 'react'
import * as maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import './Map.css'

const Map: React.FC = () => {
  const mapContainer = useRef<HTMLDivElement>(null)
  const mapRef = useRef<maplibregl.Map | null>(null)

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

    // Log map events for debugging
    mapRef.current.on('load', () => {
      console.log('Map loaded successfully')
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

  return (
    <div className="map-container">
      <div ref={mapContainer} className="map" />
      <div className="map-overlay">
        <div className="map-info">
          <p><strong>Status:</strong> Map initialized</p>
          <p><strong>Tiles:</strong> OpenStreetMap (temporary)</p>
          <p><strong>Center:</strong> Oslo, Norway</p>
        </div>
      </div>
    </div>
  )
}

export default Map 