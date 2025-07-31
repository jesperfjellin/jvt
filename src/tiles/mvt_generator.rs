use anyhow::Result;
use crate::{TileCoord, Config};
use crate::database::DatabasePool;
use tokio_postgres::Row;

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
        
        // Query actual geometries from PostGIS using ST_AsMVT
        let mvt_query = "
            WITH bounds AS (
                SELECT ST_TileEnvelope($1, $2, $3) AS geom
            )
            SELECT ST_AsMVT(q, 'planet', 4096) AS mvt
            FROM (
                SELECT 
                    osm_id,
                    tags,
                    ST_AsMVTGeom(way, bounds.geom, 4096, 256, true) AS geom
                FROM planet_osm_point, bounds
                WHERE way && bounds.geom
                    AND ST_Intersects(way, bounds.geom)
                UNION ALL
                SELECT 
                    osm_id,
                    tags,
                    ST_AsMVTGeom(way, bounds.geom, 4096, 256, true) AS geom
                FROM planet_osm_line, bounds
                WHERE way && bounds.geom
                    AND ST_Intersects(way, bounds.geom)
                UNION ALL
                SELECT 
                    osm_id,
                    tags,
                    ST_AsMVTGeom(way, bounds.geom, 4096, 256, true) AS geom
                FROM planet_osm_polygon, bounds
                WHERE way && bounds.geom
                    AND ST_Intersects(way, bounds.geom)
            ) AS q
        ";
        
        let result = self.database
            .query_one(mvt_query, &[&(coord.z as i32), &(coord.x as i32), &(coord.y as i32)])
            .await;
        
        match result {
            Ok(row) => {
                let mvt_data: Option<Vec<u8>> = row.get(0);
                if let Some(data) = mvt_data {
                    if !data.is_empty() {
                        tracing::debug!("Generated MVT tile {} with {} bytes", coord.to_string(), data.len());
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
                tracing::error!("Failed to generate MVT tile {}: {}", coord.to_string(), e);
                Ok(vec![])
            }
        }
    }

    /// Generate MVT tiles for a batch of coordinates
    pub async fn generate_tiles(&self, coords: &[TileCoord]) -> Result<Vec<(TileCoord, Vec<u8>)>> {
        let mut results = Vec::new();
        
        for coord in coords {
            match self.generate_tile(coord).await {
                Ok(tile_data) => {
                    results.push((coord.clone(), tile_data));
                }
                Err(e) => {
                    tracing::error!("Failed to generate tile {}: {}", coord.to_string(), e);
                    // Continue with other tiles instead of failing the entire batch
                }
            }
        }
        
        Ok(results)
    }
} 