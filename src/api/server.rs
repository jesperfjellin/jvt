use anyhow::Result;
use axum::{Router, extract::State, http::StatusCode, response::Json, routing::{get, post}};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;
use tower_http::cors::CorsLayer;
use tracing::{error, info, warn};

use crate::database::{BoundsDetector, DatabasePool, GeographicBounds};
use crate::{Config, TileCoord};

/// Cached bounds and tile coverage data
#[derive(Debug, Clone)]
struct BoundsCache {
    bounds: GeographicBounds,
    all_tiles: Vec<TileCoord>,
    computed_at: SystemTime,
}

/// API server for serving tile status data to the frontend
pub struct ApiServer {
    database: DatabasePool,
    config: Config,
    bounds_detector: BoundsDetector,
    bounds_cache: Arc<Mutex<Option<BoundsCache>>>,
}

/// Tile status response for the frontend
#[derive(Debug, Serialize, Deserialize)]
pub struct TileStatus {
    pub z: u8,
    pub x: u32,
    pub y: u32,
    pub last_updated: Option<String>, // ISO timestamp or null
    pub is_fresh: bool,               // true if updated in last 5 minutes
    pub change_count: u32,            // number of times this tile has been updated
    pub seconds_since_update: Option<f64>, // seconds since last update
}

/// API response containing tile status data
#[derive(Debug, Serialize)]
pub struct TileStatusResponse {
    pub tiles: Vec<TileStatus>,
    pub fresh_count: usize,
    pub stale_count: usize,
    pub last_check: String,
    pub performance_stats: PerformanceStats,
}

/// Performance comparison statistics
#[derive(Debug, Serialize)]
pub struct PerformanceStats {
    pub tiles_updated: usize,
    pub estimated_processing_time_ms: u64,
    pub full_regeneration_time_ms: u64,
    pub speedup_factor: f64,
    pub efficiency_percentage: f64,
}

/// System statistics response for efficiency metrics
#[derive(Debug, Serialize)]
pub struct SystemStatsResponse {
    pub database_size: String,
    pub total_geometries: u64,
    pub points_count: u64,
    pub lines_count: u64,
    pub polygons_count: u64,
    pub pending_tiles: u64,
    pub processing_rate: String,
    pub efficiency_ratio: String,
}

impl ApiServer {
    pub fn new(database: DatabasePool, config: Config) -> Self {
        let bounds_detector = BoundsDetector::new(database.clone(), config.clone());
        Self {
            database,
            config,
            bounds_detector,
            bounds_cache: Arc::new(Mutex::new(None)),
        }
    }

    /// Get or compute cached bounds and tile coverage
    async fn get_cached_bounds_and_tiles(&self) -> Result<(GeographicBounds, Vec<TileCoord>)> {
        // Check if we have valid cached data
        {
            let cache_lock = self.bounds_cache.lock().unwrap();
            if let Some(ref cached) = *cache_lock {
                // Cache is valid for 5 minutes (bounds rarely change)
                if cached
                    .computed_at
                    .elapsed()
                    .unwrap_or(std::time::Duration::MAX)
                    < std::time::Duration::from_secs(300)
                {
                    return Ok((cached.bounds.clone(), cached.all_tiles.clone()));
                }
            }
        }

        // Cache miss or expired - compute new bounds
        info!("Cache miss: computing new bounds and tile coverage");
        let bounds = self.bounds_detector.detect_data_bounds().await?;
        let zoom = self.config.tiles.max_zoom;
        let all_tiles = self.bounds_detector.generate_tile_coverage(&bounds, zoom);

        info!(
            "Cached {} tiles for zoom {} covering bounds {:?}",
            all_tiles.len(),
            zoom,
            bounds
        );

        // Update cache
        {
            let mut cache_lock = self.bounds_cache.lock().unwrap();
            *cache_lock = Some(BoundsCache {
                bounds: bounds.clone(),
                all_tiles: all_tiles.clone(),
                computed_at: SystemTime::now(),
            });
        }

        Ok((bounds, all_tiles))
    }

    /// Create the API router
    pub fn router(self) -> Router {
        let shared_state = Arc::new(self);

        Router::new()
            .route("/api/tile-status", get(get_tile_status))
            .route("/api/system-stats", get(get_system_stats))
            .route("/api/simulate", post(run_simulation))
            .route("/api/simulation-status", get(get_simulation_status))
            .route("/api/health", get(health_check))
            .layer(CorsLayer::permissive()) // Allow frontend to access API
            .with_state(shared_state)
    }

    /// Get complete tile status data for all tiles within data bounds
    pub async fn get_tile_status_data(&self) -> Result<TileStatusResponse> {
        // 1. Get cached bounds and tile coverage (efficient!)
        let (_bounds, all_tiles) = self.get_cached_bounds_and_tiles().await?;

        // 2. Get freshness status and change intensity for all tiles that have been processed
        let freshness_query = r#"
            SELECT z, x, y,
                   MAX(processed_at) as last_processed,
                   CASE 
                       WHEN MAX(processed_at) > NOW() - INTERVAL '5 minutes 30 seconds' THEN true
                       ELSE false
                   END as is_fresh,
                   COUNT(*) as change_count,
                   EXTRACT(EPOCH FROM (NOW() - MAX(processed_at)))::FLOAT8 as seconds_since_update
            FROM changed_tiles 
            WHERE processed_at IS NOT NULL
            GROUP BY z, x, y
        "#;

        let rows = self.database.query(freshness_query, &[]).await?;

        // Build a map of tile coordinates to freshness status and change intensity
        let mut tile_freshness = std::collections::HashMap::new();
        for row in rows {
            let z: i16 = row.get(0);  // smallint in PostgreSQL
            let x: i32 = row.get(1);
            let y: i32 = row.get(2);
            let last_processed: Option<SystemTime> = row.get(3);
            let is_fresh: bool = row.get(4);
            let change_count: i64 = row.get(5);
            let seconds_since_update: Option<f64> = row.get(6);

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

            tile_freshness.insert(coord, (last_updated, is_fresh, change_count as u32, seconds_since_update));
        }

        // 3. Build complete tile status response
        let mut tiles = Vec::new();
        let mut fresh_count = 0;
        let mut stale_count = 0;

        for tile_coord in all_tiles {
            let (last_updated, is_fresh, change_count, seconds_since_update) = tile_freshness
                .get(&tile_coord)
                .map(|(last, fresh, count, seconds)| (last.clone(), *fresh, *count, *seconds))
                .unwrap_or((None, false, 0, None)); // Default to stale if never processed

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
                change_count,
                seconds_since_update,
            });
        }

        // Calculate performance statistics
        let total_tiles = fresh_count + stale_count;
        let estimated_processing_time_ms = (fresh_count as f64 * 0.6) as u64; // ~0.6ms per tile
        let full_regeneration_time_ms = (total_tiles as f64 * 0.6) as u64;
        let speedup_factor = if fresh_count > 0 {
            total_tiles as f64 / fresh_count as f64
        } else {
            1.0
        };
        let efficiency_percentage = if total_tiles > 0 {
            (stale_count as f64 / total_tiles as f64) * 100.0
        } else {
            0.0
        };

        let performance_stats = PerformanceStats {
            tiles_updated: fresh_count,
            estimated_processing_time_ms,
            full_regeneration_time_ms,
            speedup_factor,
            efficiency_percentage,
        };

        Ok(TileStatusResponse {
            tiles,
            fresh_count,
            stale_count,
            last_check: chrono::Utc::now().to_rfc3339(),
            performance_stats,
        })
    }

    /// Get system statistics for efficiency metrics
    pub async fn get_system_stats(&self) -> Result<SystemStatsResponse> {
        // Get database size
        let size_query = "SELECT pg_size_pretty(pg_database_size(current_database())) as db_size";
        let size_row = self.database.query_one(size_query, &[]).await?;
        let database_size: String = size_row.get(0);

        // Get geometry counts
        let counts_query = r#"
            SELECT 
                (SELECT COUNT(*) FROM demo_points) as points,
                (SELECT COUNT(*) FROM demo_lines) as lines,
                (SELECT COUNT(*) FROM demo_polygons) as polygons
        "#;
        let counts_row = self.database.query_one(counts_query, &[]).await?;
        let points_count: i64 = counts_row.get(0);
        let lines_count: i64 = counts_row.get(1);
        let polygons_count: i64 = counts_row.get(2);
        let total_geometries = points_count + lines_count + polygons_count;

        // Get pending tiles count
        let pending_query = "SELECT COUNT(DISTINCT (z, x, y)) FROM changed_tiles WHERE processed_at IS NULL";
        let pending_row = self.database.query_one(pending_query, &[]).await?;
        let pending_tiles: i64 = pending_row.get(0);

        Ok(SystemStatsResponse {
            database_size,
            total_geometries: total_geometries as u64,
            points_count: points_count as u64,
            lines_count: lines_count as u64,
            polygons_count: polygons_count as u64,
            pending_tiles: pending_tiles as u64,
            processing_rate: "~8 minutes".to_string(),
            efficiency_ratio: "45x faster".to_string(),
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

/// API endpoint: Get system statistics
async fn get_system_stats(
    State(api_server): State<Arc<ApiServer>>,
) -> Result<Json<SystemStatsResponse>, StatusCode> {
    match api_server.get_system_stats().await {
        Ok(response) => {
            info!(
                "Served system stats: {} total geometries, {} pending tiles",
                response.total_geometries, response.pending_tiles
            );
            Ok(Json(response))
        }
        Err(e) => {
            error!("Failed to get system stats: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// Request body for simulation endpoint
#[derive(Deserialize)]
struct SimulationRequest {
    percentage: f64,
    seed: Option<i32>,
}

/// Response for simulation endpoint
#[derive(Serialize)]
struct SimulationResponse {
    message: String,
    percentage: f64,
    estimated_tiles: u32,
    session_id: Option<String>,
}

/// Response for simulation status endpoint
#[derive(Serialize)]
struct SimulationStatusResponse {
    is_running: bool,
    active_sessions: Vec<ActiveSession>,
}

/// Active simulation session info
#[derive(Serialize)]
struct ActiveSession {
    session_id: String,
    percentage: f64,
    status: String,
    started_at: String,
    minutes_running: i32,
    minutes_until_timeout: i32,
}

/// API endpoint: Run tile simulation
async fn run_simulation(
    State(api_server): State<Arc<ApiServer>>,
    Json(request): Json<SimulationRequest>,
) -> Result<Json<SimulationResponse>, StatusCode> {
    let percentage = request.percentage.clamp(1.0, 100.0) / 100.0; // Convert to 0.01-1.0 range
    let seed = request.seed.unwrap_or(12345);
    
    info!("Starting user-triggered simulation with {:.1}% of tiles (seed: {})", percentage * 100.0, seed);
    
    // Step 1: Check for active simulations and create new session
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let session_result = match api_server.database.query_one(
        session_query, 
        &[&percentage, &seed, &60i32, &"api_user"]
    ).await {
        Ok(row) => row,
        Err(e) => {
            error!("Failed to create simulation session: {}", e);
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    
    let session_id: Option<uuid::Uuid> = session_result.get(0);
    let success: bool = session_result.get(1);
    let message: String = session_result.get(2);
    
    if !success {
        warn!("Cannot start simulation: {}", message);
        return Ok(Json(SimulationResponse {
            message,
            percentage: percentage * 100.0,
            estimated_tiles: 0,
            session_id: None,
        }));
    }
    
    let session_id_str = session_id.unwrap().to_string();
    info!("Created simulation session: {}", session_id_str);
    
    // Step 2: Reset simulation state before starting new simulation
    let reset_query = "SELECT * FROM reset_simulation_state()";
    match api_server.database.query_one(reset_query, &[]).await {
        Ok(row) => {
            let reset_success: bool = row.get(0);
            let reset_message: String = row.get(1);
            
            if !reset_success {
                error!("Failed to reset simulation state: {}", reset_message);
                
                // Cleanup the session we just created
                let cleanup_query = "SELECT cleanup_simulation_session($1, 'failed')";
                let _ = api_server.database.query_one(cleanup_query, &[&session_id]).await;
                
                return Err(StatusCode::INTERNAL_SERVER_ERROR);
            }
            
            info!("Simulation state reset successfully: {}", reset_message);
        }
        Err(e) => {
            error!("Failed to reset simulation state: {}", e);
            
            // Cleanup the session we just created
            let cleanup_query = "SELECT cleanup_simulation_session($1, 'failed')";
            let _ = api_server.database.query_one(cleanup_query, &[&session_id]).await;
            
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    }
    
    // Step 3: Update session status to processing
    let update_query = "SELECT update_simulation_session($1, 'processing')";
    if let Err(e) = api_server.database.query_one(update_query, &[&session_id]).await {
        error!("Failed to update session status: {}", e);
    }
    
    // Step 4: Run the actual simulation
    let simulation_query = "SELECT * FROM simulate_tile_changes(8, $1, $2)";
    let simulation_result = match api_server.database.query_one(
        simulation_query, 
        &[&percentage, &seed]
    ).await {
        Ok(row) => {
            let selected_tiles: i32 = row.get(0);
            let points_deleted: i32 = row.get(1);
            let points_inserted: i32 = row.get(2);
            let lines_updated: i32 = row.get(3);
            let polygons_updated: i32 = row.get(4);
            
            info!(
                "Simulation completed successfully: {} tiles, {} points deleted, {} points inserted, {} lines updated, {} polygons updated",
                selected_tiles, points_deleted, points_inserted, lines_updated, polygons_updated
            );
            
            // Step 5: Mark session as completed
            let complete_query = "SELECT cleanup_simulation_session($1, 'completed')";
            if let Err(e) = api_server.database.query_one(complete_query, &[&session_id]).await {
                error!("Failed to cleanup simulation session: {}", e);
            }
            
            Ok(Json(SimulationResponse {
                message: format!(
                    "Simulation completed successfully: {} tiles processed, {} points deleted, {} points inserted, {} lines updated, {} polygons updated",
                    selected_tiles, points_deleted, points_inserted, lines_updated, polygons_updated
                ),
                percentage: percentage * 100.0,
                estimated_tiles: selected_tiles as u32,
                session_id: Some(session_id_str),
            }))
        }
        Err(e) => {
            error!("Simulation failed: {}", e);
            
            // Step 5: Mark session as failed
            let fail_query = "SELECT cleanup_simulation_session($1, 'failed')";
            if let Err(cleanup_err) = api_server.database.query_one(fail_query, &[&session_id]).await {
                error!("Failed to cleanup failed simulation session: {}", cleanup_err);
            }
            
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    };
    
    simulation_result
}

/// API endpoint: Get simulation status
async fn get_simulation_status(
    State(api_server): State<Arc<ApiServer>>,
) -> Result<Json<SimulationStatusResponse>, StatusCode> {
    // Check if any simulation is currently running
    let is_running_query = "SELECT is_simulation_running()";
    let is_running = match api_server.database.query_one(is_running_query, &[]).await {
        Ok(row) => row.get::<_, bool>(0),
        Err(e) => {
            error!("Failed to check simulation status: {}", e);
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    
    // Get active session details
    let active_sessions_query = "SELECT * FROM get_active_simulation_sessions()";
    let active_sessions = match api_server.database.query(active_sessions_query, &[]).await {
        Ok(rows) => {
            rows.into_iter().map(|row| {
                let session_id: uuid::Uuid = row.get(0);
                let percentage: f64 = row.get(1);
                let status: String = row.get(2);
                let started_at: SystemTime = row.get(3);
                let minutes_running: i32 = row.get(5);
                let minutes_until_timeout: i32 = row.get(6);
                
                let started_at_str = started_at
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .ok()
                    .and_then(|duration| {
                        chrono::DateTime::from_timestamp(duration.as_secs() as i64, 0)
                            .map(|dt| dt.to_rfc3339())
                    })
                    .unwrap_or_else(|| "Invalid timestamp".to_string());
                
                ActiveSession {
                    session_id: session_id.to_string(),
                    percentage: percentage * 100.0,
                    status,
                    started_at: started_at_str,
                    minutes_running,
                    minutes_until_timeout,
                }
            }).collect()
        }
        Err(e) => {
            error!("Failed to get active sessions: {}", e);
            return Err(StatusCode::INTERNAL_SERVER_ERROR);
        }
    };
    
    info!("Simulation status check: running={}, active_sessions={}", is_running, active_sessions.len());
    
    Ok(Json(SimulationStatusResponse {
        is_running,
        active_sessions,
    }))
}

/// API endpoint: Health check
async fn health_check() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "healthy",
        "service": "jvt-api",
        "timestamp": chrono::Utc::now().to_rfc3339()
    }))
}
