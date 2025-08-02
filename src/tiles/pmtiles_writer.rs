use anyhow::Result;
use crate::{TileCoord, Config};
use pmtiles::{PmTilesWriter as PmTilesWriterImpl, TileType, TileCoord as PmTileCoord, AsyncPmTilesReader};
use std::fs::File;

/// PMTiles archive writer for incremental updates
pub struct PmtilesWriter {
    archive_path: std::path::PathBuf,
    config: Config,
}

impl PmtilesWriter {
    /// Create a new PMTiles writer
    pub fn new(config: Config) -> Self {
        Self {
            archive_path: config.files.pmtiles_archive_path.clone(),
            config,
        }
    }

    /// Write a batch of tiles to the PMTiles archive
    pub async fn write_tiles(&mut self, tiles: &[(TileCoord, Vec<u8>)]) -> Result<()> {
        tracing::info!("Writing {} tiles to PMTiles archive: {}", 
                      tiles.len(), self.archive_path.display());

        // Create the archive directory if it doesn't exist
        if let Some(parent) = self.archive_path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        // Create the PMTiles file
        let file = File::create(&self.archive_path)?;
        let mut writer = PmTilesWriterImpl::new(TileType::Mvt).create(file)?;

        // Write each tile to the archive
        for (coord, data) in tiles {
            if !data.is_empty() {
                // Convert our TileCoord to PMTiles TileCoord
                let pm_coord = PmTileCoord::new(coord.z, coord.x, coord.y)
                    .ok_or_else(|| anyhow::anyhow!("Invalid tile coordinates: {}", coord.to_string()))?;
                writer.add_tile(pm_coord, data)?;
                tracing::debug!("Wrote tile {} with {} bytes", coord.to_string(), data.len());
            }
        }

        // Finalize the archive
        writer.finalize()?;
        tracing::info!("Successfully wrote {} tiles to PMTiles archive", tiles.len());

        Ok(())
    }



    /// Get statistics about the PMTiles archive
    pub async fn get_stats(&self) -> Result<ArchiveStats> {
        let metadata = std::fs::metadata(&self.archive_path).ok();
        
        let tile_count = if self.archive_path.exists() {
            // Try to read PMTiles metadata
            match AsyncPmTilesReader::new_with_path(&self.archive_path).await {
                Ok(_reader) => {
                    // TODO: Figure out how to get actual tile count from PMTiles
                    // For now, estimate based on file size
                    let file_size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);
                    if file_size > 1024 { // If file has content
                        // Rough estimate: assume average tile size of 2KB
                        (file_size / 2048).min(65536) // Cap at max z8 tiles
                    } else {
                        0
                    }
                }
                Err(_) => 0
            }
        } else {
            0
        };
        
        Ok(ArchiveStats {
            file_size: metadata.as_ref().map(|m| m.len()).unwrap_or(0),
            tile_count,
            last_modified: metadata.and_then(|m| m.modified().ok()),
        })
    }

    /// Check if the archive exists and is valid
    pub async fn validate_archive(&self) -> Result<bool> {
        if !self.archive_path.exists() {
            tracing::info!("PMTiles archive does not exist, will be created: {}", 
                          self.archive_path.display());
            return Ok(false);
        }

        // Try to read the PMTiles file to validate it
        match AsyncPmTilesReader::new_with_path(&self.archive_path).await {
            Ok(_) => {
                tracing::info!("PMTiles archive is valid: {}", self.archive_path.display());
                Ok(true)
            }
            Err(e) => {
                tracing::warn!("PMTiles archive is invalid: {}", e);
                Ok(false)
            }
        }
    }
}

#[derive(Debug)]
pub struct ArchiveStats {
    pub file_size: u64,
    pub tile_count: u64,
    pub last_modified: Option<std::time::SystemTime>,
}

impl std::fmt::Display for ArchiveStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "PMTiles Archive: {} bytes, {} tiles", 
               self.file_size, self.tile_count)
    }
} 