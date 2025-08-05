#!/bin/bash
# synthetic_change_simulator.sh - Real 5% change simulator using new SQL functions
# Simulates realistic changes in exactly ~5% of tiles with local edits only

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/gis}"

echo "$(date): Starting REAL 5% change simulation..."

# File lock coordination
LOCK_FILE="/tmp/data_generation_in_progress"
COMPLETION_FILE="/tmp/data_generation_complete"

# Wait for previous tile processing to complete
while [ -f "/tmp/tile_processing_in_progress" ]; do
    echo "$(date): Waiting for tile processing to complete..."
    sleep 30
done

# Create our lock file
touch "$LOCK_FILE"
rm -f "$COMPLETION_FILE"

echo "$(date): Running realistic change simulation (exactly 5% of tiles, local edits only)..."

# Test the tile selection first to verify it's working correctly  
echo "$(date): Testing tile selection algorithm..."
psql "$DATABASE_URL" -tA <<'SQL' || echo "$(date): Selection test logging failed (continuing)"
SELECT format(
    'Selection test: %s tiles selected (%s%% of %s total tiles)',
    selected_tiles, actual_percentage, total_tiles
)
FROM test_tile_selection(8, 0.05);
SQL

# Run the actual simulation (this is the critical part - don't let it fail)
echo "$(date): Executing change simulation..."
SIMULATION_RESULT=$(psql "$DATABASE_URL" -tA -v ON_ERROR_STOP=1 <<'SQL'
SELECT format(
    'Simulation results: %s tiles affected, %s points deleted, %s points inserted, %s lines updated, %s polygons updated',
    selected_tiles, points_deleted, points_inserted, lines_updated, polygons_updated
)
FROM simulate_changes_5min(8, 0.05);
SQL
)

if [ $? -eq 0 ]; then
    echo "$(date): $SIMULATION_RESULT"
else
    echo "$(date): ERROR - Change simulation failed!" >&2
    exit 1
fi

# Show pending tiles globally
PENDING_COUNT=$(psql "$DATABASE_URL" -t -c "
SELECT COUNT(DISTINCT (z, x, y))
FROM changed_tiles 
WHERE processed_at IS NULL;
" | tr -d ' ')

echo "  Pending tiles for regeneration: $PENDING_COUNT"

# Show current data totals with size estimates
echo ""
echo "$(date): Current database status:"
psql "$DATABASE_URL" -c "
SELECT 
    'Points' as feature_type,
    COUNT(*) as total_count,
    pg_size_pretty(pg_total_relation_size('demo_points')) as table_size
FROM demo_points
UNION ALL
SELECT 
    'Lines' as feature_type,
    COUNT(*) as total_count,
    pg_size_pretty(pg_total_relation_size('demo_lines')) as table_size
FROM demo_lines
UNION ALL  
SELECT 
    'Polygons' as feature_type,
    COUNT(*) as total_count,
    pg_size_pretty(pg_total_relation_size('demo_polygons')) as table_size
FROM demo_polygons
ORDER BY feature_type;
"

# Signal completion and release lock
touch "$COMPLETION_FILE"
rm -f "$LOCK_FILE"

echo ""
echo "$(date): Real 5% change simulation complete - tiles queued for processing!"