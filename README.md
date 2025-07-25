# JVT - Incremental Vector Tiles

Live, low-latency world map built from OpenStreetMap planet snapshots with minutely replication diffs. Built with Rust, PostGIS, and PMTiles.

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

### 3. Import Planet Data

Your planet file is already at `D:\data\gis\osm\planet\planet-latest.osm.pbf` (86GB). The import will take several hours and expand to ~700GB in PostgreSQL.

```bash
# Run the planet import (takes 4-8 hours)
docker-compose run --rm jvt-worker /usr/local/bin/import_planet.sh
```

### 4. Start the Worker

```bash
# Start the Rust tile worker
docker-compose up jvt-worker -d

# Monitor logs
docker-compose logs -f jvt-worker
```

### 5. Setup Minutely Updates

Add to your host's crontab (runs every 5 minutes):
```bash
*/5 * * * * docker-compose exec jvt-worker /usr/local/bin/update_tiles.sh >> /var/log/tiles/cron.log 2>&1
```

## Architecture

- **PostGIS Database**: Stores OSM data (~700GB on D: drive)
- **OSM2PGSQL**: Handles replication diffs every 5 minutes  
- **Rust Worker**: Generates vector tiles and maintains PMTiles archive
- **PMTiles Archive**: Incremental tile storage (grows over time)

## Storage Layout

```
D:\data\gis\
├── postgres-data\     # PostgreSQL data (~700GB)
├── pmtiles\           # PMTiles archive (grows incrementally)
└── osm\
    └── planet\
        └── planet-latest.osm.pbf  # Your 86GB source file
```

## Monitoring

```bash
# Database size
docker-compose exec postgres psql -U postgres -d gis -c "
SELECT pg_size_pretty(pg_database_size('gis'));"

# Recent tile batches
docker-compose exec postgres psql -U postgres -d gis -c "
SELECT * FROM changed_tile_batches ORDER BY started_at DESC LIMIT 5;"

# PMTiles archive size
ls -lh D:\data\gis\pmtiles\planet.pmtiles
```
