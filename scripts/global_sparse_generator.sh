#!/bin/bash
# global_sparse_generator.sh - Generate minimal global coverage for JVT demo
# Creates 1-3 geometries per z8 tile across the entire planet

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting global sparse data generation..."

# Configuration
GLOBAL_ID_START=100000000  # Start IDs from 100 million
TILES_PER_BATCH=1000       # Process 1000 tiles at once
GEOMETRIES_PER_TILE=2      # 1-3 simple points per tile

# Calculate z8 tile bounds (256x256 = 65,536 total tiles)
echo "$(date): Generating minimal global coverage (z8: 256x256 tiles)"

generate_tile_center() {
    local x=$1
    local y=$2
    
    # Very simple coordinate mapping (good enough for demo)
    # Longitude: map x (0-255) to (-180, 180)  
    local lon=$((x * 360 / 256 - 180))
    
    # Latitude: map y (0-255) to (80, -80) (inverted because tile y=0 is north)
    local lat=$((80 - y * 160 / 256))
    
    echo "$lon $lat"
}

# Generate sparse global data
TOTAL_TILES=$((256 * 256))
PROCESSED=0
BATCH_NUM=0

echo "$(date): Creating sparse data for $TOTAL_TILES tiles globally..."

for x in $(seq 0 255); do
    for y in $(seq 0 255); do
        # Get tile center coordinates
        COORDS=$(generate_tile_center $x $y)
        read -r LON LAT <<< "$COORDS"
        
        # Skip extreme polar regions (simple heuristic)
        # Focus on populated latitudes for more realistic demo
        if (( LAT < -70 || LAT > 75 )); then
            continue
        fi
        
        # Add 1-3 simple points near tile center
        for i in $(seq 1 $GEOMETRIES_PER_TILE); do
            # Add small random offset within tile bounds (simple integer math)
            local rand_lon_offset=$(( (RANDOM % 3) - 1 ))  # -1, 0, or 1 degree offset
            local rand_lat_offset=$(( (RANDOM % 3) - 1 ))  # -1, 0, or 1 degree offset
            OFFSET_LON=$((LON + rand_lon_offset))
            OFFSET_LAT=$((LAT + rand_lat_offset))
            
            GLOBAL_ID=$((GLOBAL_ID_START + PROCESSED * GEOMETRIES_PER_TILE + i))
            
            # Insert minimal point geometry
            psql "$DATABASE_URL" -c "
            INSERT INTO planet_osm_point (osm_id, way, tags) 
            VALUES (
                $GLOBAL_ID,
                ST_Transform(ST_SetSRID(ST_MakePoint($OFFSET_LON, $OFFSET_LAT), 4326), 3857),
                'name => \"Global Demo Point $GLOBAL_ID\", demo => \"global_sparse\", tile => \"$x/$y\"'::hstore
            ) ON CONFLICT (osm_id) DO NOTHING;" > /dev/null 2>&1
        done
        
        PROCESSED=$((PROCESSED + 1))
        
        # Progress update every 1000 tiles
        if (( PROCESSED % 1000 == 0 )); then
            PROGRESS=$((PROCESSED * 100 / TOTAL_TILES))
            echo "$(date): Progress: $PROGRESS% ($PROCESSED/$TOTAL_TILES tiles)"
        fi
    done
done

echo "$(date): Global sparse data generation complete!"
echo "$(date): Created data for $PROCESSED tiles worldwide"

# Show statistics
GLOBAL_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(*) FROM planet_osm_point WHERE osm_id >= $GLOBAL_ID_START;
" | tr -d ' ')

echo "$(date): Total global demo points: $GLOBAL_COUNT"
echo "$(date): Ready for worldwide tile regeneration demo!"