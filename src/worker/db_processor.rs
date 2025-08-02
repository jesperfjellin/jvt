use super::TileBatch;
use crate::database::DatabasePool;
use crate::{Config, TileCoord};
use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::HashSet;
use std::time::SystemTime;
use tracing::{debug, info};

/// Processor for database-based tile change detection
pub struct DatabaseTileProcessor {
    database: DatabasePool,
    config: Config,
}

impl DatabaseTileProcessor {
    /// Create a new database tile processor
    pub fn new(database: DatabasePool, config: Config) -> Self {
        Self { database, config }
    }

    /// Process a notification from the database and return affected tiles
    pub async fn process_notification(&self, notification_payload: &str) -> Result<TileBatch> {
        info!("Processing notification payload: {}", notification_payload);

        // Parse the JSON notification
        let payload: Value = serde_json::from_str(notification_payload)
            .context("Failed to parse notification payload as JSON")?;

        let table_name = payload
            .get("table")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let operation = payload
            .get("operation")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown");
        let tile_count = payload
            .get("tile_count")
            .and_then(|v| v.as_u64())
            .unwrap_or(0);

        info!(
            "Change detected: {} {} affected {} tiles",
            operation, table_name, tile_count
        );

        // Get pending tiles from database
        self.get_pending_tiles().await
    }

    /// Get a batch of pending tiles from the changed_tiles table
    pub async fn get_pending_tiles(&self) -> Result<TileBatch> {
        debug!("Fetching pending tiles batch from database");

        // Process tiles in batches of 1000 to avoid overwhelming the system
        let batch_size = 1000i32;
        let query = "SELECT z, x, y, count FROM get_pending_tiles($1)";
        let rows = self
            .database
            .query(query, &[&batch_size])
            .await
            .context("Failed to get pending tiles")?;

        let mut batch = TileBatch::new();
        let mut tile_set = HashSet::new();

        for row in rows {
            let z: i32 = row.get(0);
            let x: i32 = row.get(1);
            let y: i32 = row.get(2);
            let change_count: i64 = row.get(3);

            // Filter by max zoom if configured
            if z as u8 <= self.config.tiles.max_zoom {
                let coord = TileCoord::new(z as u8, x as u32, y as u32);
                debug!(
                    "Found changed tile {} (changed {} times)",
                    coord.to_string(),
                    change_count
                );
                tile_set.insert(coord);
            } else {
                debug!(
                    "Skipping tile {}/{}/{} (zoom {} > max {})",
                    z, x, y, z, self.config.tiles.max_zoom
                );
            }
        }

        // Add all unique tiles to the batch
        for coord in tile_set {
            batch.add_tile(coord);
        }

        let summary = batch.summary();
        info!("Retrieved pending tiles: {}", summary);

        Ok(batch)
    }

    /// Mark a batch of tiles as processed in the database
    pub async fn mark_tiles_processed(&self, batch: &TileBatch) -> Result<()> {
        if batch.is_empty() {
            return Ok(());
        }

        info!("Marking {} tiles as processed", batch.len());

        // Use a simple UPDATE query instead of the complex JSON function
        let mut updated_count = 0;

        for coord in &batch.tiles {
            let query = "UPDATE changed_tiles SET processed_at = NOW() WHERE z = $1 AND x = $2 AND y = $3 AND processed_at IS NULL";
            let result = self
                .database
                .execute(
                    query,
                    &[&(coord.z as i32), &(coord.x as i32), &(coord.y as i32)],
                )
                .await
                .context("Failed to mark tile as processed")?;
            updated_count += result;
        }

        info!("Marked {} tile changes as processed", updated_count);
        Ok(())
    }

    /// Get statistics about pending changes
    pub async fn get_change_stats(&self) -> Result<ChangeStats> {
        let query = r#"
            SELECT 
                COUNT(*) as total_changes,
                COUNT(DISTINCT z) as zoom_levels,
                COUNT(DISTINCT (z, x, y)) as unique_tiles,
                MIN(changed_at) as oldest_change,
                MAX(changed_at) as newest_change
            FROM changed_tiles 
            WHERE processed_at IS NULL
        "#;

        let row = self
            .database
            .query_one(query, &[])
            .await
            .context("Failed to get change statistics")?;

        Ok(ChangeStats {
            total_changes: row.get::<_, i64>(0) as u64,
            zoom_levels: row.get::<_, i64>(1) as u64,
            unique_tiles: row.get::<_, i64>(2) as u64,
            oldest_change: row.get(3),
            newest_change: row.get(4),
        })
    }

    /// Clean up old processed changes to prevent table bloat
    pub async fn cleanup_processed_changes(&self, older_than_hours: u32) -> Result<u64> {
        let query = r#"
            DELETE FROM changed_tiles 
            WHERE processed_at IS NOT NULL 
              AND processed_at < NOW() - INTERVAL '%d hours'
        "#;

        let formatted_query = query.replace("%d", &older_than_hours.to_string());
        let result = self
            .database
            .execute(&formatted_query, &[])
            .await
            .context("Failed to cleanup processed changes")?;

        info!("Cleaned up {} old processed tile changes", result);
        Ok(result)
    }
}

#[derive(Debug)]
pub struct ChangeStats {
    pub total_changes: u64,
    pub zoom_levels: u64,
    pub unique_tiles: u64,
    pub oldest_change: Option<SystemTime>,
    pub newest_change: Option<SystemTime>,
}

impl std::fmt::Display for ChangeStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Change Stats: {} changes affecting {} unique tiles across {} zoom levels",
            self.total_changes, self.unique_tiles, self.zoom_levels
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_notification_parsing() {
        let payload = r#"{"table": "planet_osm_point", "operation": "INSERT", "tile_count": 5}"#;
        let parsed: Value = serde_json::from_str(payload).unwrap();

        assert_eq!(
            parsed.get("table").unwrap().as_str().unwrap(),
            "planet_osm_point"
        );
        assert_eq!(parsed.get("operation").unwrap().as_str().unwrap(), "INSERT");
        assert_eq!(parsed.get("tile_count").unwrap().as_u64().unwrap(), 5);
    }
}
