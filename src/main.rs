use anyhow::Result;
use tracing::{info, error, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use tokio::time::{sleep, Duration};

use jvt::{Config, TileCoord};
use jvt::database::{DatabasePool, NotificationListener};
use jvt::worker::{DirtyTilesProcessor, TileBatch};

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
    
    // Create dirty tiles processor
    let processor = DirtyTilesProcessor::new(config.clone());
    
    // Main worker loop
    run_worker_loop(&mut listener, &processor, &config).await?;
    
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

/// Main worker loop - listen for notifications and process tiles
async fn run_worker_loop(
    listener: &mut NotificationListener,
    processor: &DirtyTilesProcessor,
    config: &Config,
) -> Result<()> {
    info!("Starting worker loop (timeout: {}s)", config.worker.batch_timeout_secs);
    
    loop {
        match listener.wait_for_notification(
            Duration::from_secs(config.worker.batch_timeout_secs)
        ).await {
            Ok(Some(notification)) => {
                info!("Received notification: {} bytes payload", 
                      notification.payload.len());
                
                match process_notification(listener, processor, &notification).await {
                    Ok(()) => {
                        info!("Successfully processed notification");
                    }
                    Err(e) => {
                        error!("Failed to process notification: {}", e);
                        // Continue loop - don't exit on processing errors
                    }
                }
            }
            Ok(None) => {
                // Timeout occurred - this is normal
                debug_worker_status().await;
            }
            Err(e) => {
                error!("Error waiting for notification: {}", e);
                warn!("Sleeping 10s before retrying...");
                sleep(Duration::from_secs(10)).await;
            }
        }
    }
}

/// Process a single notification
async fn process_notification(
    listener: &NotificationListener,
    processor: &DirtyTilesProcessor,
    notification: &jvt::database::listener::TileNotification,
) -> Result<()> {
    // Parse the notification to get file path
    let dirty_tiles_file = listener.parse_notification(notification)?;
    
    // Validate the file
    let file_info = processor.validate_file(&dirty_tiles_file)?;
    info!("Processing dirty tiles file: {}", file_info);
    
    // Process the file into a tile batch
    let batch = processor.process_file(&dirty_tiles_file)?;
    
    if batch.is_empty() {
        warn!("No valid tiles found in {}", dirty_tiles_file.display());
        return Ok(());
    }
    
    let summary = batch.summary();
    info!("Tile batch ready: {}", summary);
    
    // TODO: Generate MVT tiles for the batch
    // TODO: Write to PMTiles archive
    // TODO: Update audit tables
    
    info!("Processed {} tiles from {}", batch.len(), dirty_tiles_file.display());
    
    Ok(())
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
