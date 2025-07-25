use std::collections::HashSet;
use std::path::PathBuf;
use chrono::{DateTime, Utc};
use crate::TileCoord;

/// A batch of tiles to be processed together
#[derive(Debug, Clone)]
pub struct TileBatch {
    pub tiles: HashSet<TileCoord>,
    pub source_file: PathBuf,
    pub created_at: DateTime<Utc>,
    pub min_zoom: u8,
    pub max_zoom: u8,
}

impl TileBatch {
    /// Create a new empty tile batch
    pub fn new(source_file: PathBuf) -> Self {
        Self {
            tiles: HashSet::new(),
            source_file,
            created_at: Utc::now(),
            min_zoom: u8::MAX,
            max_zoom: 0,
        }
    }

    /// Add a tile coordinate to the batch
    pub fn add_tile(&mut self, coord: TileCoord) {
        self.min_zoom = self.min_zoom.min(coord.z);
        self.max_zoom = self.max_zoom.max(coord.z);
        self.tiles.insert(coord);
    }

    /// Get the number of tiles in the batch
    pub fn len(&self) -> usize {
        self.tiles.len()
    }

    /// Check if the batch is empty
    pub fn is_empty(&self) -> bool {
        self.tiles.is_empty()
    }

    /// Get tiles grouped by zoom level
    pub fn tiles_by_zoom(&self) -> Vec<(u8, Vec<&TileCoord>)> {
        let mut by_zoom: std::collections::BTreeMap<u8, Vec<&TileCoord>> = std::collections::BTreeMap::new();
        
        for tile in &self.tiles {
            by_zoom.entry(tile.z).or_default().push(tile);
        }
        
        by_zoom.into_iter().collect()
    }

    /// Get a summary of the batch for logging
    pub fn summary(&self) -> BatchSummary {
        let mut zoom_counts = std::collections::BTreeMap::new();
        
        for tile in &self.tiles {
            *zoom_counts.entry(tile.z).or_insert(0) += 1;
        }

        BatchSummary {
            total_tiles: self.tiles.len(),
            min_zoom: if self.is_empty() { 0 } else { self.min_zoom },
            max_zoom: if self.is_empty() { 0 } else { self.max_zoom },
            zoom_distribution: zoom_counts,
            source_file: self.source_file.clone(),
            created_at: self.created_at,
        }
    }

    /// Filter tiles by maximum zoom level
    pub fn filter_max_zoom(&mut self, max_zoom: u8) {
        self.tiles.retain(|tile| tile.z <= max_zoom);
        // Recalculate zoom bounds
        self.recalculate_zoom_bounds();
    }

    /// Recalculate min/max zoom after filtering
    fn recalculate_zoom_bounds(&mut self) {
        if self.tiles.is_empty() {
            self.min_zoom = u8::MAX;
            self.max_zoom = 0;
        } else {
            self.min_zoom = self.tiles.iter().map(|t| t.z).min().unwrap_or(0);
            self.max_zoom = self.tiles.iter().map(|t| t.z).max().unwrap_or(0);
        }
    }
}

#[derive(Debug)]
pub struct BatchSummary {
    pub total_tiles: usize,
    pub min_zoom: u8,
    pub max_zoom: u8,
    pub zoom_distribution: std::collections::BTreeMap<u8, usize>,
    pub source_file: PathBuf,
    pub created_at: DateTime<Utc>,
}

impl std::fmt::Display for BatchSummary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "TileBatch: {} tiles (z{}-z{}), source: {}, created: {}",
            self.total_tiles,
            self.min_zoom,
            self.max_zoom,
            self.source_file.display(),
            self.created_at.format("%Y-%m-%d %H:%M:%S UTC")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tile_batch_creation() {
        let mut batch = TileBatch::new(PathBuf::from("/tmp/test.txt"));
        
        assert!(batch.is_empty());
        assert_eq!(batch.len(), 0);
        
        batch.add_tile(TileCoord::new(10, 100, 200));
        batch.add_tile(TileCoord::new(12, 300, 400));
        batch.add_tile(TileCoord::new(10, 101, 201)); // Different tile, same zoom
        
        assert!(!batch.is_empty());
        assert_eq!(batch.len(), 3);
        assert_eq!(batch.min_zoom, 10);
        assert_eq!(batch.max_zoom, 12);
    }

    #[test]
    fn test_tile_deduplication() {
        let mut batch = TileBatch::new(PathBuf::from("/tmp/test.txt"));
        
        let coord = TileCoord::new(10, 100, 200);
        batch.add_tile(coord.clone());
        batch.add_tile(coord); // Duplicate
        
        assert_eq!(batch.len(), 1); // Should deduplicate
    }

    #[test]
    fn test_zoom_filtering() {
        let mut batch = TileBatch::new(PathBuf::from("/tmp/test.txt"));
        
        batch.add_tile(TileCoord::new(8, 100, 200));
        batch.add_tile(TileCoord::new(12, 300, 400));
        batch.add_tile(TileCoord::new(16, 500, 600));
        
        batch.filter_max_zoom(14);
        
        assert_eq!(batch.len(), 2); // Should remove z16 tile
        assert_eq!(batch.max_zoom, 12);
    }
} 