# JVT - Incremental Vector Tiles

Live, low-latency vector tiles with database-driven change detection. Built with Rust, PostGIS, and PMTiles.

## Quick Start

### 1. Setup Environment

Create a `.env` file:
```bash
cp env.template .env
# Edit .env and set POSTGRES_PASSWORD to a secure password
```

### 2. Start Database

```bash
# Start PostgreSQL with PostGIS
docker-compose up postgres -d

# Wait for database to be ready
docker-compose logs -f postgres
```

### 3. Import Norway OSM Data

```bash
# Download Norway OSM data first
wget https://download.geofabrik.de/europe/norway-latest.osm.pbf -P /mnt/c/_data/GIS/osm/

# Run the Norway import (takes 10-30 minutes)
docker-compose run --rm jvt-worker /usr/local/bin/import_norway.sh
```

### 4. Start the Worker

```bash
# Start the Rust tile worker
docker-compose up jvt-worker -d

# Monitor logs
docker-compose logs -f jvt-worker
```

### 5. Monitor the Pipeline

The system automatically:
- Creates initial global data on startup
- Simulates data changes every 5 minutes
- Processes tiles every 5 minutes when changes occur

```bash
# Monitor logs
docker-compose logs -f jvt-worker
docker-compose logs -f jvt-data-simulator
```

## Architecture

- **PostGIS Database**: Stores synthetic global demo data with change detection triggers  
- **Database Triggers**: Automatically detect changes and queue tiles for regeneration
- **Rust Worker**: Processes tiles every 5 minutes and generates vector tiles
- **Data Simulator**: Creates data changes every 5 minutes to demonstrate the pipeline
- **PMTiles Archive**: Incremental tile storage that grows over time

## Storage Layout

```
jvt/
├── logs/              # Application logs
├── pmtiles_data/      # PMTiles archive (Docker volume)
└── postgres_data/     # PostgreSQL data (Docker volume)
```

## Monitoring

```bash
# Database size
docker-compose exec postgres psql -U postgres -d gis -c "
SELECT pg_size_pretty(pg_database_size('gis'));"

# Recent tile batches
docker-compose exec postgres psql -U postgres -d gis -c "
SELECT * FROM changed_tile_batches ORDER BY started_at DESC LIMIT 5;"

# Pending tile changes
docker-compose exec postgres psql -U postgres -d gis -c "
SELECT z, x, y, count FROM get_pending_tiles() LIMIT 10;"

# PMTiles archive stats
docker-compose exec jvt-worker ls -lh /var/lib/pmtiles/
```
