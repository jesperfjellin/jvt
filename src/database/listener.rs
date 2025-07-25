use std::path::PathBuf;
use tokio_postgres::{Client, NoTls};
use tokio::time::{timeout, Duration};
use anyhow::{Context, Result};
use tracing::{info, warn, error, debug};

/// PostgreSQL notification listener for tile updates
pub struct NotificationListener {
    client: Client,
    channel: String,
}

/// Notification received from PostgreSQL
#[derive(Debug, Clone)]
pub struct TileNotification {
    pub channel: String,
    pub payload: String,
    pub process_id: u32,
}

impl NotificationListener {
    /// Create a new notification listener
    pub async fn new(database_url: &str, channel: &str) -> Result<Self> {
        info!("Creating notification listener for channel: {}", channel);
        
        let (client, connection) = tokio_postgres::connect(database_url, NoTls)
            .await
            .context("Failed to connect to PostgreSQL for notifications")?;

        // Spawn the connection handler
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                error!("PostgreSQL notification connection error: {}", e);
            }
        });

        let mut listener = Self {
            client,
            channel: channel.to_string(),
        };

        // Subscribe to the channel
        listener.subscribe().await?;

        Ok(listener)
    }

    /// Subscribe to the notification channel
    async fn subscribe(&mut self) -> Result<()> {
        let listen_query = format!("LISTEN {}", self.channel);
        self.client
            .execute(&listen_query, &[])
            .await
            .context("Failed to LISTEN to notification channel")?;
        
        info!("Listening for notifications on channel: {}", self.channel);
        Ok(())
    }

    /// Wait for the next notification with a timeout
    pub async fn wait_for_notification(&mut self, timeout_duration: Duration) -> Result<Option<TileNotification>> {
        // For tokio-postgres, we need to implement notification listening differently
        // This is a simplified version - in practice you'd use a connection stream
        match timeout(timeout_duration, async {
            loop {
                // Check for notifications (this would be handled by the connection in practice)
                tokio::time::sleep(Duration::from_millis(100)).await;
                // This is a placeholder - the actual implementation would use
                // the connection's notification stream
                return Ok::<(), tokio_postgres::Error>(());
            }
        }).await {
            Ok(_) => {
                // For now, return None (no notification received)
                // TODO: Implement proper notification handling
                debug!("Notification timeout after {:?}", timeout_duration);
                Ok(None)
            }
            Err(_) => {
                // Timeout occurred
                debug!("Notification timeout after {:?}", timeout_duration);
                Ok(None)
            }
        }
    }

    /// Parse notification payload to extract dirty tiles file path
    pub fn parse_notification(&self, notification: &TileNotification) -> Result<PathBuf> {
        // Expected payload format: "/var/cache/renderd/dirty_tiles.20250724_193245.txt"
        let path_str = notification.payload.trim();
        
        if path_str.is_empty() {
            return Err(anyhow::anyhow!("Empty notification payload"));
        }

        let path = PathBuf::from(path_str);
        
        if !path.exists() {
            warn!("Dirty tiles file does not exist: {}", path_str);
            return Err(anyhow::anyhow!("Dirty tiles file not found: {}", path_str));
        }

        info!("Parsed dirty tiles file: {}", path_str);
        Ok(path)
    }

    /// Get statistics about the listener
    pub async fn get_stats(&self) -> Result<ListenerStats> {
        let notifications_query = "
            SELECT 
                pg_stat_get_db_numbackends(pg_database.oid) as active_connections,
                pg_stat_get_db_xact_commit(pg_database.oid) as committed_transactions
            FROM pg_database 
            WHERE datname = current_database()
        ";

        let row = self.client
            .query_one(notifications_query, &[])
            .await
            .context("Failed to get listener statistics")?;

        Ok(ListenerStats {
            active_connections: row.get::<_, i64>(0) as u64,
            committed_transactions: row.get::<_, i64>(1) as u64,
        })
    }
}

#[derive(Debug)]
pub struct ListenerStats {
    pub active_connections: u64,
    pub committed_transactions: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_notification_parsing() {
        let notification = TileNotification {
            channel: "tiles_updated".to_string(),
            payload: "/tmp/test_dirty_tiles.txt".to_string(),
            process_id: 12345,
        };

        // Create a temporary file for testing
        std::fs::write("/tmp/test_dirty_tiles.txt", "14/8234/5425\n").unwrap();
        
        let listener = NotificationListener {
            client: unsafe { std::mem::zeroed() }, // Not used in this test
            channel: "tiles_updated".to_string(),
        };

        let path = listener.parse_notification(&notification).unwrap();
        assert_eq!(path.to_string_lossy(), "/tmp/test_dirty_tiles.txt");

        // Clean up
        std::fs::remove_file("/tmp/test_dirty_tiles.txt").ok();
    }
} 