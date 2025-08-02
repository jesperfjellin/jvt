use anyhow::Result;
use axum::{Router, extract::State, http::StatusCode, response::Json, routing::get};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::SystemTime;
use tower_http::cors::CorsLayer;
use tracing::{error, info};

use crate::database::{BoundsDetector, DatabasePool};
use crate::{Config, TileCoord};

/// API server for serving tile status data to the frontend
pub struct ApiServer {
    database: DatabasePool,
    config: Config,
    bounds_detector: BoundsDetector,
}

/// Tile status response for the frontend
#[derive(Debug, Serialize, Deserialize)]
pub struct TileStatus {
    pub z: u8,
    pub x: u32,
    pub y: u32,
    pub last_updated: Option<String>, // ISO timestamp or null
    pub is_fresh: bool,               // true if updated in last 5 minutes
}

/// API response containing tile status data
#[derive(Debug, Serialize)]
pub struct TileStatusResponse {
    pub tiles: Vec<TileStatus>,
    pub fresh_count: usize,
    pub stale_count: usize,
    pub last_check: String,
}

impl ApiServer {
    pub fn new(database: DatabasePool, config: Config) -> Self {
        let bounds_detector = BoundsDetector::new(database.clone(), config.clone());
        Self {
            database,
            config,
            bounds_detector,
        }
    }

    /// Create the API router
    pub fn router(self) -> Router {
        let shared_state = Arc::new(self);

        Router::new()
            .route("/api/tile-status", get(get_tile_status))
            .route("/api/health", get(health_check))
            .layer(CorsLayer::permissive()) // Allow frontend to access API
            .with_state(shared_state)
    }

    /// Get complete tile status data for all tiles within data bounds
    pub async fn get_tile_status_data(&self) -> Result<TileStatusResponse> {
        // 1. Detect data bounds
        let bounds = self.bounds_detector.detect_data_bounds().await?;
        info!("Data bounds detected: {:?}", bounds);

        // 2. Generate complete tile coverage for the configured zoom level
        let zoom = self.config.tiles.max_zoom; // Use max zoom from config
        let all_tiles = self.bounds_detector.generate_tile_coverage(&bounds, zoom);
        info!(
            "Generated {} total tiles for zoom {}",
            all_tiles.len(),
            zoom
        );

        // 3. Get freshness status for all tiles that have been processed
        let freshness_query = r#"
            SELECT z, x, y,
                   MAX(processed_at) as last_processed,
                   CASE 
                       WHEN MAX(processed_at) > NOW() - INTERVAL '5 minutes' THEN true
                       ELSE false
                   END as is_fresh
            FROM changed_tiles 
            WHERE processed_at IS NOT NULL
            GROUP BY z, x, y
        "#;

        let rows = self.database.query(freshness_query, &[]).await?;

        // Build a map of tile coordinates to freshness status
        let mut tile_freshness = std::collections::HashMap::new();
        for row in rows {
            let z: i32 = row.get(0);
            let x: i32 = row.get(1);
            let y: i32 = row.get(2);
            let last_processed: Option<SystemTime> = row.get(3);
            let is_fresh: bool = row.get(4);

            let coord = TileCoord::new(z as u8, x as u32, y as u32);
            let last_updated = last_processed.and_then(|st| {
                st.duration_since(SystemTime::UNIX_EPOCH)
                    .ok()
                    .map(|duration| {
                        let secs = duration.as_secs();
                        chrono::DateTime::from_timestamp(secs as i64, 0)
                            .map(|dt| dt.to_rfc3339())
                            .unwrap_or_else(|| "Invalid timestamp".to_string())
                    })
            });

            tile_freshness.insert(coord, (last_updated, is_fresh));
        }

        // 4. Build complete tile status response
        let mut tiles = Vec::new();
        let mut fresh_count = 0;
        let mut stale_count = 0;

        for tile_coord in all_tiles {
            let (last_updated, is_fresh) = tile_freshness
                .get(&tile_coord)
                .map(|(last, fresh)| (last.clone(), *fresh))
                .unwrap_or((None, false)); // Default to stale if never processed

            if is_fresh {
                fresh_count += 1;
            } else {
                stale_count += 1;
            }

            tiles.push(TileStatus {
                z: tile_coord.z,
                x: tile_coord.x,
                y: tile_coord.y,
                last_updated,
                is_fresh,
            });
        }

        Ok(TileStatusResponse {
            tiles,
            fresh_count,
            stale_count,
            last_check: chrono::Utc::now().to_rfc3339(),
        })
    }
}

/// API endpoint: Get tile status data
async fn get_tile_status(
    State(api_server): State<Arc<ApiServer>>,
) -> Result<Json<TileStatusResponse>, StatusCode> {
    match api_server.get_tile_status_data().await {
        Ok(response) => {
            info!(
                "Served tile status: {} fresh, {} stale tiles",
                response.fresh_count, response.stale_count
            );
            Ok(Json(response))
        }
        Err(e) => {
            error!("Failed to get tile status: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// API endpoint: Health check
async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "jvt-api",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}
