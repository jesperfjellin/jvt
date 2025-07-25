use std::sync::Arc;
use tokio_postgres::{Client, NoTls, Row};
use anyhow::{Context, Result};
use tracing::{info, error};

/// Database connection pool for PostgreSQL
#[derive(Clone)]
pub struct DatabasePool {
    client: Arc<Client>,
}

impl DatabasePool {
    /// Create a new database connection pool
    pub async fn new(database_url: &str) -> Result<Self> {
        info!("Connecting to PostgreSQL: {}", mask_password(database_url));
        
        let (client, connection) = tokio_postgres::connect(database_url, NoTls)
            .await
            .context("Failed to connect to PostgreSQL")?;

        // Spawn the connection handler
        tokio::spawn(async move {
            if let Err(e) = connection.await {
                error!("PostgreSQL connection error: {}", e);
            }
        });

        // Test the connection
        let version = client
            .query_one("SELECT version()", &[])
            .await
            .context("Failed to test database connection")?;
        
        info!("Connected to PostgreSQL: {}", 
              version.get::<_, String>(0));

        Ok(Self {
            client: Arc::new(client),
        })
    }

    /// Get a reference to the underlying client
    pub fn client(&self) -> &Client {
        &self.client
    }

    /// Execute a query and return all rows
    pub async fn query(&self, query: &str, params: &[&(dyn tokio_postgres::types::ToSql + Sync)]) -> Result<Vec<Row>> {
        self.client
            .query(query, params)
            .await
            .context("Database query failed")
    }

    /// Execute a query and return a single row
    pub async fn query_one(&self, query: &str, params: &[&(dyn tokio_postgres::types::ToSql + Sync)]) -> Result<Row> {
        self.client
            .query_one(query, params)
            .await
            .context("Database query_one failed")
    }

    /// Execute a query that doesn't return rows
    pub async fn execute(&self, query: &str, params: &[&(dyn tokio_postgres::types::ToSql + Sync)]) -> Result<u64> {
        self.client
            .execute(query, params)
            .await
            .context("Database execute failed")
    }

    /// Test database connectivity
    pub async fn health_check(&self) -> Result<()> {
        self.client
            .query_one("SELECT 1", &[])
            .await
            .context("Database health check failed")?;
        Ok(())
    }
}

/// Mask password in database URL for logging
fn mask_password(url: &str) -> String {
    if let Some(start) = url.find("://") {
        if let Some(at_pos) = url[start + 3..].find('@') {
            let prefix = &url[..start + 3];
            let suffix = &url[start + 3 + at_pos..];
            if let Some(colon_pos) = url[start + 3..start + 3 + at_pos].find(':') {
                let username = &url[start + 3..start + 3 + colon_pos];
                return format!("{}{}:***{}", prefix, username, suffix);
            }
        }
    }
    url.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mask_password() {
        let url = "postgresql://user:password@localhost:5432/db";
        let masked = mask_password(url);
        assert_eq!(masked, "postgresql://user:***@localhost:5432/db");
    }

    #[test]
    fn test_mask_password_no_password() {
        let url = "postgresql://user@localhost:5432/db";
        let masked = mask_password(url);
        assert_eq!(masked, "postgresql://user@localhost:5432/db");
    }
} 