use anyhow::Result;
use tracing::{info, error, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use tokio::time::{sleep, Duration};

use jvt::Config;
use jvt::database::{DatabasePool, NotificationListener};
use jvt::worker::DatabaseTileProcessor;
use jvt::tiles::{MvtGenerator, PmtilesWriter};
use jvt::api::ApiServer;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing/logging
    init_logging()?;
    
    info!("Starting JVT (Incremental Vector Tiles) worker");
    
    // Load configuration from environment
    let config = Config::from_env()?;
    info!("Configuration loaded successfully");
    
    // Initialize database connection
    let database = DatabasePool::new(&config.database.url).await?;
    info!("Database connection established");
    
    // Test database connectivity
    database.health_check().await?;
    info!("Database health check passed");
    
    // Create notification listener
    let mut listener = NotificationListener::new(
        &config.database.url,
        &config.database.notification_channel,
    ).await?;
    info!("Notification listener initialized for channel: {}", 
          config.database.notification_channel);
    
    // Create database tile processor
    let processor = DatabaseTileProcessor::new(database.clone(), config.clone());
    
    // Create MVT generator and PMTiles writer
    let mvt_generator = MvtGenerator::new(database.clone(), config.clone());
    let mut pmtiles_writer = PmtilesWriter::new(config.clone());
    
    // Validate PMTiles archive exists
    pmtiles_writer.validate_archive().await?;
    info!("PMTiles archive ready for updates");
    
    // Start API server
    let api_server = ApiServer::new(database.clone(), config.clone());
    let app = api_server.router();
    
    let api_handle = tokio::spawn(async move {
        let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await?;
        info!("API server listening on http://0.0.0.0:8080");
        axum::serve(listener, app).await.map_err(anyhow::Error::from)
    });
    
    // Start worker loop
    let worker_handle = tokio::spawn(async move {
        run_worker_loop(&mut listener, &processor, &mvt_generator, &mut pmtiles_writer, &config).await
    });
    
    // Wait for both to complete (or one to fail)
    tokio::select! {
        result = api_handle => {
            match result? {
                Ok(_) => info!("API server completed"),
                Err(e) => error!("API server failed: {}", e),
            }
        }
        result = worker_handle => {
            match result? {
                Ok(_) => info!("Worker completed"),
                Err(e) => error!("Worker failed: {}", e),
            }
        }
    }
    
    Ok(())
}

/// Initialize structured logging
fn init_logging() -> Result<()> {
    let env_filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    
    tracing_subscriber::registry()
        .with(env_filter)
        .with(tracing_subscriber::fmt::layer())
        .init();
    
    Ok(())
}

/// Main worker loop - batched processing every 5 minutes
async fn run_worker_loop(
    listener: &mut NotificationListener,
    processor: &DatabaseTileProcessor,
    mvt_generator: &MvtGenerator,
    pmtiles_writer: &mut PmtilesWriter,
    config: &Config,
) -> Result<()> {
    info!("Starting batched worker loop (processes tiles every {}s)", config.worker.batch_timeout_secs);
    
    loop {
        // Wait for notifications OR timeout after 5 minutes
        match listener.wait_for_notification(
            Duration::from_secs(config.worker.batch_timeout_secs)
        ).await {
            Ok(Some(notification)) => {
                info!("Received change notification: {} bytes payload", 
                      notification.payload.len());
                // Don't process immediately - just acknowledge that changes occurred
                info!("Change recorded, will process in next batch cycle");
            }
            Ok(None) => {
                // Timeout occurred - time to process pending tiles!
                info!("5-minute timer expired, processing pending tiles...");
                
                match process_pending_tiles_batch(processor, mvt_generator, pmtiles_writer).await {
                    Ok(processed_count) => {
                        if processed_count > 0 {
                            info!("Successfully processed {} tiles in batch", processed_count);
                        } else {
                            info!("No pending tiles to process");
                        }
                    }
                    Err(e) => {
                        error!("Failed to process tile batch: {}", e);
                        // Continue loop - don't exit on processing errors
                    }
                }
            }
            Err(e) => {
                error!("Error waiting for notification: {}", e);
                warn!("Sleeping 10s before retrying...");
                sleep(Duration::from_secs(10)).await;
            }
        }
    }
}

/// Process all pending tiles in one batch (called every 5 minutes)
async fn process_pending_tiles_batch(
    processor: &DatabaseTileProcessor,
    mvt_generator: &MvtGenerator,
    pmtiles_writer: &mut PmtilesWriter,
) -> Result<usize> {
    // Get all pending tiles from the database
    let batch = processor.get_pending_tiles().await?;
    
    if batch.is_empty() {
        return Ok(0);
    }
    
    let summary = batch.summary();
    info!("Processing tile batch: {}", summary);
    
    // Convert batch tiles to a vector for MVT generation
    let tile_coords: Vec<_> = batch.tiles.iter().cloned().collect();
    
    // Generate MVT tiles for all changed coordinates
    info!("Generating {} MVT tiles...", tile_coords.len());
    let tile_data = mvt_generator.generate_tiles(&tile_coords).await?;
    
    // Update PMTiles archive with new tiles
    info!("Updating PMTiles archive with {} tiles...", tile_data.len());
    pmtiles_writer.write_tiles(&tile_data).await?;
    
    // Mark tiles as processed in database
    processor.mark_tiles_processed(&batch).await?;
    
    info!("Completed processing {} tiles in batch", batch.len());
    
    Ok(batch.len())
}

/// Log worker status during idle periods
async fn debug_worker_status() {
    use tracing::debug;
    
    debug!("Worker heartbeat - waiting for notifications...");
    
    // TODO: Add more detailed status:
    // - Current PMTiles archive size
    // - Recent processing stats
    // - Memory usage
}
