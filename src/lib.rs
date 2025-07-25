pub mod config;
pub mod database;
pub mod tiles;
pub mod worker;

// Re-export common types
pub use config::Config;

/// Core tile coordinate representation  
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TileCoord {
    pub z: u8,
    pub x: u32,
    pub y: u32,
}

impl TileCoord {
    pub fn new(z: u8, x: u32, y: u32) -> Self {
        Self { z, x, y }
    }
    
    /// Parse from "z/x/y" format used in dirty_tiles.txt
    pub fn from_str(s: &str) -> Result<Self, String> {
        let parts: Vec<&str> = s.trim().split('/').collect();
        if parts.len() != 3 {
            return Err(format!("Invalid tile coordinate format: {}", s));
        }
        
        let z = parts[0].parse::<u8>()
            .map_err(|_| format!("Invalid zoom level: {}", parts[0]))?;
        let x = parts[1].parse::<u32>()
            .map_err(|_| format!("Invalid x coordinate: {}", parts[1]))?;
        let y = parts[2].parse::<u32>()
            .map_err(|_| format!("Invalid y coordinate: {}", parts[2]))?;
            
        Ok(TileCoord::new(z, x, y))
    }
    
    /// Format as "z/x/y" string
    pub fn to_string(&self) -> String {
        format!("{}/{}/{}", self.z, self.x, self.y)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tile_coord_parsing() {
        let coord = TileCoord::from_str("14/8234/5425").unwrap();
        assert_eq!(coord.z, 14);
        assert_eq!(coord.x, 8234);
        assert_eq!(coord.y, 5425);
        assert_eq!(coord.to_string(), "14/8234/5425");
    }

    #[test]
    fn test_invalid_tile_coord() {
        assert!(TileCoord::from_str("invalid").is_err());
        assert!(TileCoord::from_str("14/8234").is_err());
        assert!(TileCoord::from_str("14/8234/5425/extra").is_err());
    }
} 