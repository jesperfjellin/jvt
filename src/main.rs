use anyhow::Result;
use tokio::time::{Duration, sleep};
use tracing::{error, info, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use jvt::Config;
use jvt::api::ApiServer;
use jvt::database::{DatabasePool, NotificationListener};
use jvt::tiles::{MvtGenerator, PmtilesWriter};
use jvt::worker::DatabaseTileProcessor;

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
    let mut listener =
        NotificationListener::new(&config.database.url, &config.database.notification_channel)
            .await?;
    info!(
        "Notification listener initialized for channel: {}",
        config.database.notification_channel
    );

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
        axum::serve(listener, app)
            .await
            .map_err(anyhow::Error::from)
    });

    // Start worker loop
    let worker_handle = tokio::spawn(async move {
        run_worker_loop(
            &mut listener,
            &processor,
            &mvt_generator,
            &mut pmtiles_writer,
            &config,
        )
        .await
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

/// Main worker loop - immediate processing on notifications with periodic cleanup
async fn run_worker_loop(
    listener: &mut NotificationListener,
    processor: &DatabaseTileProcessor,
    mvt_generator: &MvtGenerator,
    pmtiles_writer: &mut PmtilesWriter,
    config: &Config,
) -> Result<()> {
    info!("Starting worker loop (immediate processing on notifications only)");

    loop {
        // Wait for notifications with short timeout as fallback
        match listener.wait_for_notification(Duration::from_secs(5)).await
        {
            Ok(Some(notification)) => {
                info!(
                    "Received change notification: {} bytes payload - processing immediately",
                    notification.payload.len()
                );
                
                // Process tiles immediately when notification is received
                match process_pending_tiles_batch(processor, mvt_generator, pmtiles_writer).await {
                    Ok(processed_count) => {
                        if processed_count > 0 {
                            info!("Successfully processed {} tiles from notification", processed_count);
                            
                            // Wait a bit for the frontend to fetch the results
                            tokio::time::sleep(Duration::from_secs(10)).await;
                            
                            // Reset tile status for next simulation
                            match processor.reset_to_baseline().await {
                                Ok(reset_count) => {
                                    info!("Reset {} tiles for next simulation", reset_count);
                                }
                                Err(e) => {
                                    error!("Failed to reset tiles for next simulation: {}", e);
                                }
                            }
                        }
                    }
                    Err(e) => {
                        error!("Failed to process tiles from notification: {}", e);
                    }
                }
            }
            Ok(None) => {
                // Timeout occurred - check for pending tiles (notifications may not be working)
                tracing::debug!("Checking for pending tiles...");
                
                // Check if there are any pending tiles that we missed
                match process_pending_tiles_batch(processor, mvt_generator, pmtiles_writer).await {
                    Ok(processed_count) => {
                        if processed_count > 0 {
                            warn!("Found {} pending tiles that weren't triggered by notification!", processed_count);
                        } else {
                            tracing::debug!("No pending tiles found during timeout check");
                        }
                    }
                    Err(e) => {
                        error!("Failed to check pending tiles during timeout: {}", e);
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

/// Process all pending tiles immediately when notification is received
async fn process_pending_tiles_batch(
    processor: &DatabaseTileProcessor,
    mvt_generator: &MvtGenerator,
    pmtiles_writer: &mut PmtilesWriter,
) -> Result<usize> {
    let mut total_processed = 0;
    let mut batch_count = 0;
    
    loop {
        // Get next batch of pending tiles from the database
        let batch = processor.get_pending_tiles().await?;

        if batch.is_empty() {
            break;
        }

        batch_count += 1;
        info!("Processing {} tiles from simulation (chunk #{})...", batch.len(), batch_count);

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

        total_processed += batch.len();
        info!("Completed chunk #{} with {} tiles (total: {})", batch_count, batch.len(), total_processed);

        // Safety check: if we've processed more than 100k tiles in one cycle, something might be wrong
        if total_processed > 100_000 {
            warn!("Processed {} tiles in one cycle - stopping to prevent runaway processing", total_processed);
            break;
        }
    }

    if total_processed > 0 {
        info!("Completed simulation: {} total tiles processed", total_processed);
    }

    Ok(total_processed)
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


