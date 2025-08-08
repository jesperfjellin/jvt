use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub database: DatabaseConfig,
    pub tiles: TileConfig,
    pub files: FileConfig,
    pub worker: WorkerConfig,
    pub geometry: GeometryConfig,
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
    pub pmtiles_archive_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkerConfig {
    pub batch_timeout_secs: u64,
    pub max_retries: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GeometryConfig {
    pub schema: String,
    pub tables: Vec<String>,
    pub geometry_column: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database: DatabaseConfig {
                url: "postgresql://postgres:password@localhost:5432/gis".to_string(),
                notification_channel: "tiles_updated".to_string(),
            },
            tiles: TileConfig {
                max_zoom: 8,
                min_zoom: 8,
                tile_size: 4096,
                buffer: 256,
            },
            files: FileConfig {
                pmtiles_archive_path: PathBuf::from("/var/lib/pmtiles/planet.pmtiles"),
            },
            worker: WorkerConfig {
                batch_timeout_secs: 30, // 30 seconds for responsive processing
                max_retries: 1,
            },
            geometry: GeometryConfig {
                // Require explicit configuration via env
                schema: String::new(),
                tables: vec![],
                // Default assumption (configurable via GEOMETRY_COLUMN)
                geometry_column: "geom".to_string(),
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

        if let Ok(pmtiles_path) = std::env::var("PMTILES_ARCHIVE_PATH") {
            config.files.pmtiles_archive_path = PathBuf::from(pmtiles_path);
        }

        // Override geometry configuration with environment variables if present
        if let Ok(schema) = std::env::var("GEOMETRY_SCHEMA") {
            config.geometry.schema = schema;
        }

        if let Ok(tables) = std::env::var("GEOMETRY_TABLES") {
            config.geometry.tables = tables
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }

        if let Ok(column) = std::env::var("GEOMETRY_COLUMN") {
            config.geometry.geometry_column = column;
        }

        // Validate required geometry configuration
        if config.geometry.schema.is_empty() {
            anyhow::bail!("GEOMETRY_SCHEMA must be set in the environment for JVT core");
        }
        if config.geometry.tables.is_empty() {
            anyhow::bail!("GEOMETRY_TABLES must be set (comma-separated) in the environment for JVT core");
        }

        tracing::info!("Configuration loaded: tiles z{}-z{}, schema '{}', tables {:?}", config.tiles.min_zoom, config.tiles.max_zoom, config.geometry.schema, config.geometry.tables);
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = Config::default();
        assert_eq!(config.tiles.max_zoom, 8); // MVP: z8 only
        assert_eq!(config.tiles.min_zoom, 8); // MVP: z8 only
        assert_eq!(config.database.notification_channel, "tiles_updated");
    }
}
