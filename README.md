# JVT — Incremental Vector Tiles

PostGIS‑native, event‑driven vector tile pipeline that regenerates only the tiles that changed. Built with Rust, PostGIS, and MVT, with pluggable outputs (PMTiles or ZXY) and unopinionated delivery.

## Quick start

JVT assumes you have an existing PostGIS database. Point JVT at your database and select an output mode.

1) Configure environment:
```bash
cp env.template .env
# Set DATABASE_URL, GEOMETRY_SCHEMA/GEOMETRY_TABLES/GEOMETRY_COLUMN, OUTPUT_MODE
```

2) Build and start JVT:
```bash
docker compose up --build -d
```

## Architecture (high level)

- **PostGIS**: geometry source of truth and change queue (`changed_tiles` with unique `(z,x,y)`).
- **Change signaling**: `LISTEN/NOTIFY` wakes the worker; timeout poll is a fallback.
- **Rust worker**: dequeues tiles in batches, generates MVT via `ST_AsMVT` (with `ST_AsMVTGeom`), and writes to the selected sink.
- **Outputs**: single‑file PMTiles archive or ZXY files on disk; each batch also emits a manifest (for user‑defined upload/CDN pipelines).
- **Frontend demo**: MapLibre dashboard to visualize updated vs stale tiles and show timing/efficiency.

## Output modes

JVT is unopinionated about delivery. Choose one at runtime via environment:

- `OUTPUT_MODE=pmtiles` — write a single PMTiles file at `PMTILES_ARCHIVE_PATH` with atomic swap.
- `OUTPUT_MODE=zxy` — write `{z}/{x}/{y}.mvt[.gz]` under `ZXY_OUTPUT_DIR` with atomic rename.
- `OUTPUT_MODE=manifest` — emit NDJSON manifests of changed tiles to `MANIFEST_DIR` and stdout.

These artifacts fit any pipeline (rclone/awscli/rsync, internal CI/CD, S3/MinIO/Ceph, or simple web roots).


## Configuration

Environment variables (see `.env` or `env.template`):

- `DATABASE_URL` — PostGIS URL
- `GEOMETRY_SCHEMA`, `GEOMETRY_TABLES`, `GEOMETRY_COLUMN` — input geometry config
- `OUTPUT_MODE` — `pmtiles` | `zxy` | `manifest`
- `PMTILES_ARCHIVE_PATH` — path for PMTiles when in pmtiles mode
- `ZXY_OUTPUT_DIR` — base directory for ZXY when in zxy mode
- `MANIFEST_DIR` — directory for batch manifests
- `TILES_MAX_Z`, `TILES_MIN_Z`, `TILE_SIZE`, `TILE_BUFFER` — tiling knobs


## Design notes

- Tiles are generated per `z/x/y` by querying intersecting features within `ST_TileEnvelope` and encoding via `ST_AsMVT`.
- JVT favors simple, class‑agnostic heuristics for low‑zoom: zoom‑scaled simplification and minimum length/area thresholds (configurable).
- Neighbor tiles are expanded by a buffer to avoid edge artifacts.
- Worker uses bounded concurrency and database timeouts; multi‑worker safety uses batch reads and deduplication at the queue.
- Delivery is externalized: JVT writes artifacts and manifests; users publish via their own storage/CDN tooling.

