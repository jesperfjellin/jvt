use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use crate::{Config, TileCoord};
use crate::database::DatabasePool;

/// Geographic bounds in WGS84 coordinates
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeographicBounds {
    pub min_lon: f64,
    pub min_lat: f64, 
    pub max_lon: f64,
    pub max_lat: f64,
}

/// Service for detecting data bounds and generating tile coverage
pub struct BoundsDetector {
    database: DatabasePool,
    config: Config,
}

impl BoundsDetector {
    pub fn new(database: DatabasePool, config: Config) -> Self {
        Self { database, config }
    }

    /// Detect the geographic bounds of all geometry data in configured tables
    pub async fn detect_data_bounds(&self) -> Result<GeographicBounds> {
        tracing::info!("Detecting data bounds for tables: {:?}", self.config.geometry.tables);
        
        // Build query to get extent from each table separately, then combine
        let mut extent_parts = Vec::new();
        
        for table in &self.config.geometry.tables {
            let qualified_table = format!("{}.{}", self.config.geometry.schema, table);
            extent_parts.push(format!(
                "SELECT ST_Transform(ST_SetSRID(ST_Extent({}), 3857), 4326) as bounds FROM {} WHERE {} IS NOT NULL",
                self.config.geometry.geometry_column,
                qualified_table,
                self.config.geometry.geometry_column
            ));
        }
        
        let bounds_query = format!(
            r#"
            WITH table_extents AS ({})
            SELECT 
                ST_XMin(combined_bounds) as min_lon,
                ST_YMin(combined_bounds) as min_lat,
                ST_XMax(combined_bounds) as max_lon,
                ST_YMax(combined_bounds) as max_lat
            FROM (
                SELECT ST_Extent(bounds) as combined_bounds
                FROM table_extents
                WHERE bounds IS NOT NULL
            ) final_extent
            "#,
            extent_parts.join(" UNION ALL ")
        );
        
        tracing::debug!("Bounds detection query: {}", bounds_query);
        
        let row = self.database.query_one(&bounds_query, &[]).await
            .context("Failed to detect data bounds")?;
        
        let bounds = GeographicBounds {
            min_lon: row.get(0),
            min_lat: row.get(1),
            max_lon: row.get(2),
            max_lat: row.get(3),
        };
        
        tracing::info!("Detected data bounds: {:?}", bounds);
        Ok(bounds)
    }
    
    /// Generate complete tile coverage for the given bounds at specified zoom level
    pub fn generate_tile_coverage(&self, bounds: &GeographicBounds, zoom: u8) -> Vec<TileCoord> {
        let mut tiles = Vec::new();
        
        // Calculate tile bounds for the geographic extent
        let n = 2_u32.pow(zoom as u32);
        
        // Convert bounds to tile coordinates
        let min_x = ((bounds.min_lon + 180.0) / 360.0 * n as f64).floor() as u32;
        let max_x = ((bounds.max_lon + 180.0) / 360.0 * n as f64).floor() as u32;
        
        let min_y = ((1.0 - (bounds.max_lat.to_radians().tan() + 1.0 / bounds.max_lat.to_radians().cos()).ln() / std::f64::consts::PI) / 2.0 * n as f64).floor() as u32;
        let max_y = ((1.0 - (bounds.min_lat.to_radians().tan() + 1.0 / bounds.min_lat.to_radians().cos()).ln() / std::f64::consts::PI) / 2.0 * n as f64).floor() as u32;
        
        // Clamp to valid tile ranges
        let min_x = min_x.min(n - 1);
        let max_x = max_x.min(n - 1);
        let min_y = min_y.min(n - 1);
        let max_y = max_y.min(n - 1);
        
        // Generate all tiles in the bounding box
        for x in min_x..=max_x {
            for y in min_y..=max_y {
                tiles.push(TileCoord::new(zoom, x, y));
            }
        }
        
        tracing::info!(
            "Generated {} tiles for zoom {} covering bounds {:?}",
            tiles.len(),
            zoom,
            bounds
        );
        
        tiles
    }
}

impl GeographicBounds {
    /// Check if bounds are valid
    pub fn is_valid(&self) -> bool {
        self.min_lon < self.max_lon && 
        self.min_lat < self.max_lat &&
        self.min_lon >= -180.0 && self.max_lon <= 180.0 &&
        self.min_lat >= -90.0 && self.max_lat <= 90.0
    }
    
    /// Get the center point of the bounds
    pub fn center(&self) -> (f64, f64) {
        (
            (self.min_lon + self.max_lon) / 2.0,
            (self.min_lat + self.max_lat) / 2.0
        )
    }
}