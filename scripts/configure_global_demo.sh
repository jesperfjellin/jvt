#!/bin/bash
# configure_global_demo.sh - Configure JVT for global sparse demo
# Prepares the system for worldwide tile coverage demonstration

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Configuring JVT for global sparse demo..."

# Clean existing Norway-only data (optional)
read -p "Remove existing Norway data to start fresh? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "$(date): Cleaning existing OSM data..."
    psql "$DATABASE_URL" -c "
    DELETE FROM planet_osm_point WHERE osm_id < 100000000;
    DELETE FROM planet_osm_line WHERE osm_id < 100000000;  
    DELETE FROM planet_osm_polygon WHERE osm_id < 100000000;
    DELETE FROM planet_osm_roads WHERE osm_id < 100000000;
    DELETE FROM changed_tiles;
    "
    echo "$(date): Cleaned Norway data"
fi

# Generate global sparse coverage
echo "$(date): Generating global sparse coverage..."
./scripts/global_sparse_generator.sh

# Show new global bounds
echo "$(date): Detecting new global bounds..."
psql "$DATABASE_URL" -c "
WITH bounds AS (
    SELECT ST_Transform(ST_SetSRID(ST_Extent(way), 3857), 4326) as bbox
    FROM planet_osm_point 
    WHERE way IS NOT NULL
)
SELECT 
    'Global Coverage:' as info,
    ST_XMin(bbox) as min_lon,
    ST_YMin(bbox) as min_lat, 
    ST_XMax(bbox) as max_lon,
    ST_YMax(bbox) as max_lat,
    ST_XMax(bbox) - ST_XMin(bbox) as lon_span,
    ST_YMax(bbox) - ST_YMin(bbox) as lat_span
FROM bounds;
"

# Update Docker Compose for global demo
echo "$(date): Updating configuration for global scale..."

# Create global demo configuration
cat > docker-compose.global.yml << 'EOF'
# Global sparse demo configuration
# Use: docker-compose -f docker-compose.yml -f docker-compose.global.yml up

services:
  jvt-data-simulator:
    volumes:
      - ./scripts:/usr/local/scripts:ro
    command: >
      bash -c "
      echo '[$(date)] Starting GLOBAL sparse data simulation...' >> /var/log/tiles/global-simulation.log;
      while true; do /usr/local/scripts/global_change_simulator.sh >> /var/log/tiles/global-simulation.log 2>&1;
      echo '[$(date)] Sleeping 120 seconds before next global cycle...' >> /var/log/tiles/global-simulation.log; 
      sleep 120; done
      "
EOF

echo "$(date): Global demo configuration ready!"
echo ""
echo "To start global demo:"
echo "  docker-compose -f docker-compose.yml -f docker-compose.global.yml up"
echo ""  
echo "Expected results:"
echo "  • ~65,536 tiles globally (z8 coverage)"
echo "  • ~50 changes per 2-minute cycle"
echo "  • Worldwide tile freshness visualization"
echo "  • Changes scattered across 6 continents"