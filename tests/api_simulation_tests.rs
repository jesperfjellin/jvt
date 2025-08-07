use anyhow::Result;
use std::env;

use jvt::{Config, database::DatabasePool};

/// Integration tests for API simulation state management
///
/// These tests verify that:
/// - Simulations check for active sessions before starting
/// - Simulation state is properly reset before new simulations
/// - Concurrent simulation attempts are properly handled
/// - Session tracking and cleanup work correctly

#[tokio::test]
async fn test_simulation_session_creation() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Test 1: Creating a simulation session should work when no other simulation is running
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let session_result = database
        .query_one(session_query, &[&0.05f64, &12345i32, &60i32, &"test_user"])
        .await?;

    let session_id: Option<uuid::Uuid> = session_result.get(0);
    let success: bool = session_result.get(1);
    let message: String = session_result.get(2);

    assert!(success, "Session creation should succeed: {}", message);
    assert!(session_id.is_some(), "Session ID should be returned");

    println!("✓ Simulation session creation works correctly");

    Ok(())
}

#[tokio::test]
async fn test_concurrent_simulation_prevention() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Create first simulation session (this should succeed)
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let first_result = database
        .query_one(session_query, &[&0.10f64, &12345i32, &60i32, &"test_user1"])
        .await?;

    let first_success: bool = first_result.get(1);
    assert!(first_success, "First session creation should succeed");

    // Immediately try to create a second simulation session (this should fail)
    let second_result = database
        .query_one(session_query, &[&0.10f64, &12346i32, &60i32, &"test_user2"])
        .await?;

    let second_success: bool = second_result.get(1);
    let second_message: String = second_result.get(2);

    assert!(!second_success, "Second session creation should fail");
    assert!(
        second_message.contains("active simulation"),
        "Should mention active simulation: {}",
        second_message
    );

    println!("✓ Concurrent simulation prevention works correctly");

    Ok(())
}

#[tokio::test]
async fn test_simulation_status_functions() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Check status when no simulation is running
    let is_running_query = "SELECT is_simulation_running()";
    let is_running_result = database.query_one(is_running_query, &[]).await?;
    let is_running: bool = is_running_result.get(0);

    assert!(!is_running, "No simulation should be running initially");

    // Get active sessions (should be empty)
    let active_sessions_query = "SELECT * FROM get_active_simulation_sessions()";
    let active_sessions = database.query(active_sessions_query, &[]).await?;

    assert_eq!(
        active_sessions.len(),
        0,
        "No active sessions should exist initially"
    );

    // Create a simulation session
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let session_result = database
        .query_one(session_query, &[&0.05f64, &12345i32, &60i32, &"test_user"])
        .await?;

    let success: bool = session_result.get(1);
    assert!(success, "Session creation should succeed");

    // Check status again - simulation should now be running
    let is_running_result2 = database.query_one(is_running_query, &[]).await?;
    let is_running2: bool = is_running_result2.get(0);

    assert!(
        is_running2,
        "Simulation should be running after session creation"
    );

    // Get active sessions (should have one)
    let active_sessions2 = database.query(active_sessions_query, &[]).await?;

    assert_eq!(active_sessions2.len(), 1, "One active session should exist");

    println!("✓ Simulation status functions work correctly");

    Ok(())
}

#[tokio::test]
async fn test_simulation_state_reset() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Get initial geometry counts
    let initial_counts = get_geometry_counts(&database).await?;

    // Run first simulation
    let simulation_query = "SELECT * FROM simulate_tile_changes(8, $1, $2)";
    let first_result = database
        .query_one(simulation_query, &[&0.05f64, &12345i32])
        .await?;

    let first_tiles: i32 = first_result.get(0);
    assert!(
        first_tiles > 0,
        "First simulation should process some tiles"
    );

    // Reset simulation state
    let reset_query = "SELECT * FROM reset_simulation_state()";
    let reset_result = database.query_one(reset_query, &[]).await?;

    let reset_success: bool = reset_result.get(0);
    let reset_message: String = reset_result.get(1);

    assert!(reset_success, "Reset should succeed: {}", reset_message);

    // Run second simulation with same parameters
    let second_result = database
        .query_one(simulation_query, &[&0.05f64, &12345i32])
        .await?;

    let second_tiles: i32 = second_result.get(0);

    // Verify that both simulations produced the same results
    // (This tests that state was properly reset between runs)
    assert_eq!(
        first_tiles, second_tiles,
        "Both simulations should process the same number of tiles"
    );

    println!("✓ Simulation state reset works correctly");

    Ok(())
}

#[tokio::test]
async fn test_simulation_session_cleanup() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Create a simulation session
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let session_result = database
        .query_one(session_query, &[&0.05f64, &12345i32, &60i32, &"test_user"])
        .await?;

    let session_id: Option<uuid::Uuid> = session_result.get(0);
    let success: bool = session_result.get(1);

    assert!(success, "Session creation should succeed");
    let session_id = session_id.unwrap();

    // Update session to processing
    let update_query = "SELECT update_simulation_session($1, 'processing')";
    let update_result = database.query_one(update_query, &[&session_id]).await?;
    let update_success: bool = update_result.get(0);

    assert!(update_success, "Session update should succeed");

    // Cleanup session as completed
    let cleanup_query = "SELECT cleanup_simulation_session($1, 'completed')";
    let cleanup_result = database.query_one(cleanup_query, &[&session_id]).await?;
    let cleanup_success: bool = cleanup_result.get(0);

    assert!(cleanup_success, "Session cleanup should succeed");

    // Verify session is no longer active
    let is_running_query = "SELECT is_simulation_running()";
    let is_running_result = database.query_one(is_running_query, &[]).await?;
    let is_running: bool = is_running_result.get(0);

    assert!(!is_running, "No simulation should be running after cleanup");

    println!("✓ Simulation session cleanup works correctly");

    Ok(())
}

#[tokio::test]
async fn test_simulation_error_handling() -> Result<()> {
    let config = Config::from_env()?;
    let database = DatabasePool::new(&config.database.url).await?;

    // Ensure clean state before testing
    cleanup_test_state(&database).await?;

    // Test with valid parameters (should work)
    let simulation_query = "SELECT * FROM simulate_tile_changes(8, $1, $2)";
    let valid_result = database
        .query_one(simulation_query, &[&0.05f64, &12345i32])
        .await;

    assert!(valid_result.is_ok(), "Valid simulation should succeed");

    // Test session creation with invalid timeout (should still work with clamping)
    let session_query = "SELECT * FROM create_simulation_session($1, $2, $3, $4)";
    let session_result = database
        .query_one(
            session_query,
            &[&0.05f64, &12345i32, &-10i32, &"test_user"], // Negative timeout
        )
        .await;

    // The function should handle this gracefully
    assert!(
        session_result.is_ok(),
        "Session creation should handle invalid timeout gracefully"
    );

    println!("✓ Simulation error handling works correctly");

    Ok(())
}

/// Helper function to cleanup test state
async fn cleanup_test_state(database: &DatabasePool) -> Result<()> {
    // Reset simulation state
    let _ = database
        .query_one("SELECT * FROM reset_simulation_state()", &[])
        .await;

    // Cleanup any active sessions
    let _ = database.execute(
        "UPDATE simulation_sessions SET status = 'test_cleanup', completed_at = NOW() WHERE status IN ('starting', 'processing')", 
        &[]
    ).await;

    // Cleanup expired sessions
    let _ = database
        .query_one("SELECT cleanup_expired_sessions()", &[])
        .await;

    Ok(())
}

/// Helper function to get geometry counts
async fn get_geometry_counts(database: &DatabasePool) -> Result<(i64, i64, i64)> {
    let query = r#"
        SELECT 
            (SELECT COUNT(*) FROM demo_points) as points,
            (SELECT COUNT(*) FROM demo_lines) as lines,
            (SELECT COUNT(*) FROM demo_polygons) as polygons
    "#;

    let row = database.query_one(query, &[]).await?;
    let points: i64 = row.get(0);
    let lines: i64 = row.get(1);
    let polygons: i64 = row.get(2);

    Ok((points, lines, polygons))
}
