use anyhow::{Context, Result};
use tokio::time::Duration;
use tokio_postgres::{Client, NoTls};
use tracing::{debug, error, info};

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
    pub async fn wait_for_notification(
        &mut self,
        timeout_duration: Duration,
    ) -> Result<Option<TileNotification>> {
        // Simple timeout implementation - just wait for the full duration
        // In a real implementation, this would listen for actual PostgreSQL NOTIFY events
        debug!(
            "Waiting for notifications or timeout after {:?}",
            timeout_duration
        );

        tokio::time::sleep(timeout_duration).await;

        debug!("Notification timeout after {:?}", timeout_duration);
        Ok(None) // Always timeout for now - notification handling is simplified
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

        let row = self
            .client
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
