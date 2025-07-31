use anyhow::Result;
use tracing::{info, error, warn};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
use std::collections::HashSet;

use jvt::{Config, TileCoord};
use jvt::database::DatabasePool;
use jvt::tiles::{MvtGenerator, PmtilesWriter};

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing/logging
    init_logging()?;
    
    info!("Starting JVT Initial Tile Generation (z8 only)");
    
    // Load configuration from environment
    let config = Config::from_env()?;
    info!("Configuration loaded: z{}-z{}", config.tiles.min_zoom, config.tiles.max_zoom);
    
    // Initialize database connection
    let database = DatabasePool::new(&config.database.url).await?;
    info!("Database connection established");
    
    // Test database connectivity
    database.health_check().await?;
    info!("Database health check passed");
    
    // Create MVT generator and PMTiles writer
    let mvt_generator = MvtGenerator::new(database.clone(), config.clone());
    let mut pmtiles_writer = PmtilesWriter::new(config.clone());
    
    // Validate PMTiles archive
    let archive_exists = pmtiles_writer.validate_archive()?;
    if archive_exists {
        warn!("PMTiles archive already exists, will append to it");
    } else {
        info!("Creating new PMTiles archive");
    }
    
    // Generate all z8 tiles for the planet
    let tiles = generate_all_z8_tiles();
    info!("Generated {} z8 tile coordinates", tiles.len());
    
    // Process tiles in batches
    let batch_size = 1000;
    let mut processed = 0;
    let total_tiles = tiles.len();
    
    for (batch_num, chunk) in tiles.chunks(batch_size).enumerate() {
        info!("Processing batch {}/{} (tiles {}-{})", 
              batch_num + 1, 
              (total_tiles + batch_size - 1) / batch_size,
              processed + 1,
              processed + chunk.len());
        
        // Generate MVT tiles for this batch
        let tile_data = mvt_generator.generate_tiles(chunk).await?;
        
        if !tile_data.is_empty() {
            // Write tiles to PMTiles archive
            pmtiles_writer.write_tiles(&tile_data).await?;
            info!("Wrote {} tiles to PMTiles archive", tile_data.len());
        } else {
            warn!("No tile data generated for batch {}", batch_num + 1);
        }
        
        processed += chunk.len();
        
        // Progress update
        let progress = (processed as f64 / total_tiles as f64) * 100.0;
        info!("Progress: {:.1}% ({}/{})", progress, processed, total_tiles);
    }
    
    // Show final statistics
    let stats = pmtiles_writer.get_stats().await?;
    info!("Initial tile generation complete!");
    info!("PMTiles archive: {}", stats);
    
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

/// Generate all z8 tile coordinates for the entire planet
fn generate_all_z8_tiles() -> Vec<TileCoord> {
    let mut tiles = Vec::new();
    
    // z8 has 256x256 tiles (0-255 for both x and y)
    for x in 0..256 {
        for y in 0..256 {
            tiles.push(TileCoord::new(8, x, y));
        }
    }
    
    info!("Generated {} z8 tile coordinates", tiles.len());
    tiles
} 