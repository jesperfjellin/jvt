## JVT decisions and guiding principles

### Goal
- Build an incremental, PostGIS‑native vector tiler that regenerates only changed tiles on short cadence (≈5 minutes), packaged as a simple container.

### Storage and delivery
- Prefer serving a single PMTiles file via HTTP range requests behind a web server/CDN.
- Support in‑house deployments without requiring any specific object store (no hard dependency on MinIO/Ceph).
- Do not store PMTiles inside PostGIS; avoid FTP in favor of HTTPS.

### Output modes (unopinionated handoff)
- Pluggable sinks selected by configuration:
  - pmtiles: write/update a single archive path with atomic swap.
  - zxy: write `{z}/{x}/{y}.mvt[.gz]` files under an output directory with atomic rename.
  - manifest/stdout: emit a per‑batch list of updated tiles (for user pipelines to upload/purge).
- Always publish a per‑batch manifest so users can integrate any uploader/CDN/ETL without JVT knowing their stack.

### PMTiles vs ZXY trade‑offs
- PMTiles (single file):
  - Pros: one artifact, easy distribution/backups/versioning; avoids “millions of files.”
  - Cons: requires an incremental writer strategy (append + periodic optimize) and a reader (e.g., pmtiles.js or proxy).
- ZXY (many files):
  - Pros: trivial to serve; easy targeted invalidation per tile; simplest incremental writes.
  - Cons: operationally heavy at scale due to file/object counts and listings.
- Support both; default to PMTiles first, add ZXY for teams with existing pipelines.

### Client vs server responsibilities
- Client style (MapLibre/Mapbox GL): controls final visibility (minzoom/maxzoom, styling, labeling).
- Tiler (JVT): ensures tiles contain only zoom‑appropriate data and are simplified, to keep payloads small and fast.

### Zoom levels and simplification (class‑agnostic heuristics)
- Keep rules non‑opinionated and geometric:
  - Points: include only at or above a minimum zoom.
  - Lines: include if length exceeds a zoom‑scaled threshold.
  - Polygons: include if area exceeds a zoom‑scaled threshold.
  - Simplification: use a screen‑space target tolerance converted to meters per zoom; always clip/quantize with a buffer.
- Expose thresholds in configuration so users can tune visually without code changes.

### Change detection and processing loop
- Use database change queue (`changed_tiles`) with unique `(z,x,y)` and `processed_at` to deduplicate and batch.
- Prefer event‑driven processing via PostgreSQL LISTEN/NOTIFY with a timeout poll as fallback.
- Expand affected tiles by render buffer to prevent seam artifacts.
- Bounded concurrency for tile generation; protect DB with timeouts and a real connection pool.
- Mark queue items processed (or delete) after successful write; periodic cleanup to avoid bloat.

### Deployment patterns
- Local/self‑host: write PMTiles/ZXY to a mounted path; serve via Nginx/Caddy with range support and cache headers.
- Object storage (optional): write locally, then let a user‑provided uploader publish artifacts to S3‑compatible storage/CDN.
- Atomic updates: temp file → fsync → rename (PMTiles) or per‑tile rename (ZXY); for object storage, versioned keys and alias swap.

### Near‑term implementation priorities
- Real NOTIFY consumption; keep timeout poll.
- Bounded‑concurrency tile generation.
- Minimal incremental PMTiles writer (append) + periodic optimize/compaction.
- Neighbor tile expansion; zoom‑aware geometric thresholds and simplification controlled by config.
- Per‑batch manifest output to enable user pipelines.

### Non‑goals
- Replacing tippecanoe’s full platform or prescribing domain‑specific class rules.
- Styling or client‑side cartography (left to the consuming map style).


