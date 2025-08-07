use crate::database::DatabasePool;
use crate::{Config, TileCoord};
use anyhow::Result;

/// MVT (Mapbox Vector Tiles) generator
pub struct MvtGenerator {
    database: DatabasePool,
    config: Config,
}

impl MvtGenerator {
    /// Create a new MVT generator
    pub fn new(database: DatabasePool, config: Config) -> Self {
        Self { database, config }
    }

    /// Generate an MVT tile for the given coordinates
    pub async fn generate_tile(&self, coord: &TileCoord) -> Result<Vec<u8>> {
        tracing::debug!("Generating MVT tile for {}", coord.to_string());

        // Add timeout to prevent hanging on problematic tiles
        let timeout_duration = tokio::time::Duration::from_secs(30);

        match tokio::time::timeout(timeout_duration, self.generate_tile_impl(coord)).await {
            Ok(result) => result,
            Err(_) => {
                tracing::error!("Timeout generating tile {}", coord.to_string());
                Err(anyhow::anyhow!("Tile generation timeout"))
            }
        }
    }

    /// Internal implementation of tile generation
    async fn generate_tile_impl(&self, coord: &TileCoord) -> Result<Vec<u8>> {
        // Query synthetic geometries from PostGIS using ST_AsMVT
        let mvt_query = "
            WITH bounds AS (
                SELECT ST_TileEnvelope($1, $2, $3) AS geom
            )
            SELECT COALESCE(
                (SELECT ST_AsMVT(q, 'demo', 4096) FROM (
                SELECT 
                    demo_points.id,
                    demo_points.demo_tag,
                    'point' AS type,
                    ST_AsMVTGeom(demo_points.geom, bounds.geom, 4096, 256, true) AS geom
                FROM demo_points, bounds
                WHERE demo_points.geom && bounds.geom
                    AND ST_Intersects(demo_points.geom, bounds.geom)
                UNION ALL
                SELECT 
                    demo_lines.id,
                    demo_lines.demo_tag,
                    'line' AS type,
                    ST_AsMVTGeom(demo_lines.geom, bounds.geom, 4096, 256, true) AS geom
                FROM demo_lines, bounds
                WHERE demo_lines.geom && bounds.geom
                    AND ST_Intersects(demo_lines.geom, bounds.geom)
                UNION ALL
                SELECT 
                    demo_polygons.id,
                    demo_polygons.demo_tag,
                    'polygon' AS type,
                    ST_AsMVTGeom(demo_polygons.geom, bounds.geom, 4096, 256, true) AS geom
                FROM demo_polygons, bounds
                WHERE demo_polygons.geom && bounds.geom
                    AND ST_Intersects(demo_polygons.geom, bounds.geom)
                ) AS q), ''::bytea) AS mvt
        ";

        let result = self
            .database
            .query_one(
                mvt_query,
                &[&(coord.z as i16), &(coord.x as i32), &(coord.y as i32)],
            )
            .await;

        match result {
            Ok(row) => {
                let mvt_data: Option<Vec<u8>> = row.get(0);
                if let Some(data) = mvt_data {
                    if !data.is_empty() {
                        tracing::debug!(
                            "Generated MVT tile {} with {} bytes",
                            coord.to_string(),
                            data.len()
                        );
                        Ok(data)
                    } else {
                        tracing::debug!("Empty MVT tile for {}", coord.to_string());
                        Ok(vec![])
                    }
                } else {
                    tracing::debug!("No MVT data for {}", coord.to_string());
                    Ok(vec![])
                }
            }
            Err(e) => {
                // Check if this is just an empty tile (no geometry data)
                let error_msg = e.to_string();
                if error_msg.contains("query_one failed") || error_msg.contains("no rows") {
                    tracing::debug!(
                        "Tile {} has no geometry data, returning empty tile",
                        coord.to_string()
                    );
                    Ok(vec![])
                } else {
                    tracing::warn!("Failed to generate MVT tile {}: {}", coord.to_string(), e);
                    Err(anyhow::anyhow!("Database error: {}", e))
                }
            }
        }
    }

    /// Generate MVT tiles for a batch of coordinates
    pub async fn generate_tiles(&self, coords: &[TileCoord]) -> Result<Vec<(TileCoord, Vec<u8>)>> {
        let mut results = Vec::new();

        for coord in coords {
            tracing::debug!("Generating tile {}", coord.to_string());
            match self.generate_tile(coord).await {
                Ok(tile_data) => {
                    results.push((coord.clone(), tile_data));
                }
                Err(e) => {
                    // Check if this is just an empty tile (no geometry data)
                    let error_msg = e.to_string();
                    if error_msg.contains("query_one failed") || error_msg.contains("no rows") {
                        tracing::debug!(
                            "Tile {} has no geometry data, generating empty tile",
                            coord.to_string()
                        );
                    } else {
                        tracing::warn!("Failed to generate tile {}: {}", coord.to_string(), e);
                    }
                    // Continue with other tiles instead of failing the entire batch
                    // Add an empty tile to keep the batch size consistent
                    results.push((coord.clone(), vec![]));
                }
            }
        }

        Ok(results)
    }
}
