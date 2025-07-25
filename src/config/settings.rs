use std::path::PathBuf;
use serde::{Deserialize, Serialize};
use anyhow::Result;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub database: DatabaseConfig,
    pub tiles: TileConfig,
    pub files: FileConfig,
    pub worker: WorkerConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConfig {
    pub url: String,
    pub notification_channel: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TileConfig {
    pub max_zoom: u8,
    pub min_zoom: u8,
    pub tile_size: u32,
    pub buffer: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileConfig {
    pub dirty_tiles_path: PathBuf,
    pub pmtiles_archive_path: PathBuf,
    pub dead_letter_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerConfig {
    pub batch_timeout_secs: u64,
    pub max_retries: u32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database: DatabaseConfig {
                url: "postgresql://postgres:password@localhost:5432/gis".to_string(),
                notification_channel: "tiles_updated".to_string(),
            },
            tiles: TileConfig {
                max_zoom: 14,
                min_zoom: 0,
                tile_size: 4096,
                buffer: 256,
            },
            files: FileConfig {
                dirty_tiles_path: PathBuf::from("/var/cache/renderd"),
                pmtiles_archive_path: PathBuf::from("/var/lib/pmtiles/planet.pmtiles"),
                dead_letter_path: PathBuf::from("/var/cache/renderd/dead_letter_tiles.txt"),
            },
            worker: WorkerConfig {
                batch_timeout_secs: 30,
                max_retries: 1,
            },
        }
    }
}

impl Config {
    /// Load configuration from environment variables
    pub fn from_env() -> Result<Self> {
        let mut config = Config::default();
        
        // Override with environment variables if present
        if let Ok(db_url) = std::env::var("DATABASE_URL") {
            config.database.url = db_url;
        }
        
        if let Ok(dirty_path) = std::env::var("DIRTY_TILES_PATH") {
            config.files.dirty_tiles_path = PathBuf::from(dirty_path);
        }
        
        if let Ok(pmtiles_path) = std::env::var("PMTILES_ARCHIVE_PATH") {
            config.files.pmtiles_archive_path = PathBuf::from(pmtiles_path);
        }
        
        tracing::info!("Configuration loaded: {:?}", config);
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.tiles.max_zoom, 14);
        assert_eq!(config.database.notification_channel, "tiles_updated");
    }
} 