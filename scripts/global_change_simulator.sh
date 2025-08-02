#!/bin/bash
# global_change_simulator.sh - Simulate sparse changes across the entire globe
# Creates small changes scattered worldwide for impressive demo visualization

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting global sparse change simulation..."

# Configuration
GLOBAL_ID_START=100000000
CHANGES_PER_CYCLE=50      # 50 changes scattered globally (vs 1000 in Norway)
CONTINENTS=(
    "4.0 50.0"        # Europe  
    "-95.0 40.0"      # North America
    "-60.0 -15.0"     # South America  
    "25.0 0.0"        # Africa
    "100.0 30.0"      # Asia
    "135.0 -25.0"     # Australia
)

generate_continental_coords() {
    local continent=$1
    read -r base_lon base_lat <<< "$continent"
    
    # Generate coordinates within ~1000km of continent center
    local random_lon=$(awk "BEGIN {printf \"%.6f\", $base_lon + (rand() - 0.5) * 20}")
    local random_lat=$(awk "BEGIN {printf \"%.6f\", $base_lat + (rand() - 0.5) * 15}")
    
    echo "$random_lon $random_lat"
}

# Simulate global changes
INSERTS=0
UPDATES=0  
DELETES=0

echo "$(date): Simulating $CHANGES_PER_CYCLE changes across 6 continents..."

# 1. GLOBAL INSERTS (60% of changes)
INSERT_COUNT=$((CHANGES_PER_CYCLE * 60 / 100))
echo "$(date): Creating $INSERT_COUNT new points globally..."

for i in $(seq 1 $INSERT_COUNT); do
    # Pick random continent
    CONTINENT_IDX=$((RANDOM % 6))
    CONTINENT="${CONTINENTS[$CONTINENT_IDX]}"
    
    COORDS=$(generate_continental_coords "$CONTINENT")
    read -r LON LAT <<< "$COORDS"
    
    # Create unique global ID
    TIMESTAMP=$(date +%s)
    GLOBAL_ID=$((GLOBAL_ID_START + TIMESTAMP + i))
    
    CONTINENT_NAME=""
    case $CONTINENT_IDX in
        0) CONTINENT_NAME="Europe" ;;
        1) CONTINENT_NAME="North America" ;;  
        2) CONTINENT_NAME="South America" ;;
        3) CONTINENT_NAME="Africa" ;;
        4) CONTINENT_NAME="Asia" ;;
        5) CONTINENT_NAME="Australia" ;;
    esac
    
    psql "$DATABASE_URL" -c "
    INSERT INTO planet_osm_point (osm_id, way, tags)
    VALUES (
        $GLOBAL_ID,
        ST_Transform(ST_SetSRID(ST_MakePoint($LON, $LAT), 4326), 3857),
        'name => \"Global Change $GLOBAL_ID\", continent => \"$CONTINENT_NAME\", 
         created_at => \"$(date +%s)\", type => \"demo_insert\"'::hstore
    );" > /dev/null
    
    INSERTS=$((INSERTS + 1))
done

# 2. GLOBAL UPDATES (30% of changes)  
UPDATE_COUNT=$((CHANGES_PER_CYCLE * 30 / 100))
echo "$(date): Updating $UPDATE_COUNT existing global points..."

for i in $(seq 1 $UPDATE_COUNT); do
    # Pick random continent for movement
    CONTINENT_IDX=$((RANDOM % 6))
    CONTINENT="${CONTINENTS[$CONTINENT_IDX]}"
    
    COORDS=$(generate_continental_coords "$CONTINENT") 
    read -r LON LAT <<< "$COORDS"
    
    UPDATED=$(psql "$DATABASE_URL" -t -c "
    UPDATE planet_osm_point
    SET way = ST_Transform(ST_SetSRID(ST_MakePoint($LON, $LAT), 4326), 3857),
        tags = tags || 'updated_at => \"$(date +%s)\"'::hstore
    WHERE osm_id >= $GLOBAL_ID_START
      AND RANDOM() < 0.1  -- Update 10% of global demo points
    RETURNING osm_id;
    " | head -1 | tr -d ' ')
    
    if [ -n "$UPDATED" ] && [ "$UPDATED" != "" ]; then
        UPDATES=$((UPDATES + 1))
    fi
done

# 3. GLOBAL DELETES (10% of changes)
DELETE_COUNT=$((CHANGES_PER_CYCLE * 10 / 100))
echo "$(date): Removing $DELETE_COUNT global points..."

for i in $(seq 1 $DELETE_COUNT); do
    DELETED=$(psql "$DATABASE_URL" -t -c "
    DELETE FROM planet_osm_point 
    WHERE osm_id >= $GLOBAL_ID_START
      AND RANDOM() < 0.05  -- Delete 5% of global demo points
    RETURNING osm_id;
    " | head -1 | tr -d ' ')
    
    if [ -n "$DELETED" ] && [ "$DELETED" != "" ]; then
        DELETES=$((DELETES + 1))
    fi
done

# Show global statistics
echo ""
echo "$(date): GLOBAL CHANGE SUMMARY:"
echo "  Inserts: $INSERTS / $INSERT_COUNT (scattered globally)"
echo "  Updates: $UPDATES / $UPDATE_COUNT (moved between continents)"  
echo "  Deletes: $DELETES / $DELETE_COUNT (removed globally)"
echo "  Total changes: $((INSERTS + UPDATES + DELETES))"

# Show pending tiles worldwide
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y))
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo "  Pending tiles globally: $PENDING_COUNT"

# Show continental distribution
echo ""
echo "$(date): Current global distribution:"
psql "$DATABASE_URL" -c "
SELECT 
    COALESCE(tags->'continent', 'Unknown') as continent,
    COUNT(*) as points
FROM planet_osm_point 
WHERE osm_id >= $GLOBAL_ID_START
GROUP BY tags->'continent'
ORDER BY points DESC;
"

echo ""
echo "$(date): Global change simulation complete - worldwide tiles affected!"