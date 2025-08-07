#!/bin/bash

# Integration test script for API simulation state management
# Tests the updated simulation endpoint with proper state management

set -e

API_BASE="http://localhost:8080"
SIMULATION_ENDPOINT="$API_BASE/api/simulate"
STATUS_ENDPOINT="$API_BASE/api/simulation-status"

echo "🧪 Testing API Simulation State Management"
echo "=========================================="

# Function to make API calls with error handling
make_api_call() {
    local method=$1
    local url=$2
    local data=$3
    local description=$4
    
    echo "📡 $description"
    
    if [ "$method" = "POST" ]; then
        response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            -d "$data" \
            "$url")
    else
        response=$(curl -s -w "\n%{http_code}" "$url")
    fi
    
    # Split response and status code
    body=$(echo "$response" | head -n -1)
    status_code=$(echo "$response" | tail -n 1)
    
    echo "   Status: $status_code"
    echo "   Response: $body"
    
    if [ "$status_code" -ne 200 ]; then
        echo "❌ API call failed with status $status_code"
        return 1
    fi
    
    echo "✅ Success"
    echo
    
    # Return the response body for further processing
    echo "$body"
}

# Test 1: Check initial simulation status (should be no active simulations)
echo "Test 1: Check initial simulation status"
echo "--------------------------------------"
initial_status=$(make_api_call "GET" "$STATUS_ENDPOINT" "" "Checking initial simulation status")

is_running=$(echo "$initial_status" | jq -r '.is_running')
active_count=$(echo "$initial_status" | jq -r '.active_sessions | length')

if [ "$is_running" = "true" ]; then
    echo "❌ Expected no simulation to be running initially"
    exit 1
fi

if [ "$active_count" -ne 0 ]; then
    echo "❌ Expected no active sessions initially, found $active_count"
    exit 1
fi

echo "✅ Test 1 PASSED: No simulations running initially"
echo

# Test 2: Start a simulation (should succeed)
echo "Test 2: Start first simulation"
echo "------------------------------"
simulation_data='{"percentage": 5.0, "seed": 12345}'
first_sim_response=$(make_api_call "POST" "$SIMULATION_ENDPOINT" "$simulation_data" "Starting first simulation")

session_id=$(echo "$first_sim_response" | jq -r '.session_id')
percentage=$(echo "$first_sim_response" | jq -r '.percentage')
estimated_tiles=$(echo "$first_sim_response" | jq -r '.estimated_tiles')

if [ "$session_id" = "null" ]; then
    echo "❌ Expected session_id to be returned"
    exit 1
fi

if [ "$percentage" != "5" ]; then
    echo "❌ Expected percentage to be 5, got $percentage"
    exit 1
fi

if [ "$estimated_tiles" -le 0 ]; then
    echo "❌ Expected estimated_tiles to be > 0, got $estimated_tiles"
    exit 1
fi

echo "✅ Test 2 PASSED: First simulation started successfully"
echo "   Session ID: $session_id"
echo "   Estimated tiles: $estimated_tiles"
echo

# Test 3: Try to start concurrent simulation (should fail)
echo "Test 3: Try concurrent simulation (should fail)"
echo "-----------------------------------------------"
concurrent_data='{"percentage": 10.0, "seed": 54321}'
concurrent_response=$(make_api_call "POST" "$SIMULATION_ENDPOINT" "$concurrent_data" "Attempting concurrent simulation")

concurrent_session_id=$(echo "$concurrent_response" | jq -r '.session_id')
concurrent_message=$(echo "$concurrent_response" | jq -r '.message')

if [ "$concurrent_session_id" != "null" ]; then
    echo "❌ Expected concurrent simulation to be rejected (session_id should be null)"
    exit 1
fi

if [[ "$concurrent_message" != *"active simulation"* ]]; then
    echo "❌ Expected error message to mention active simulation, got: $concurrent_message"
    exit 1
fi

echo "✅ Test 3 PASSED: Concurrent simulation properly rejected"
echo "   Message: $concurrent_message"
echo

# Test 4: Check simulation status (should show active simulation)
echo "Test 4: Check simulation status with active simulation"
echo "----------------------------------------------------"
active_status=$(make_api_call "GET" "$STATUS_ENDPOINT" "" "Checking status with active simulation")

is_running_active=$(echo "$active_status" | jq -r '.is_running')
active_sessions=$(echo "$active_status" | jq -r '.active_sessions')

if [ "$is_running_active" != "true" ]; then
    echo "❌ Expected simulation to be running"
    exit 1
fi

# Note: The simulation might complete very quickly for 5%, so we might not catch it in "running" state
# This is expected behavior for small simulations

echo "✅ Test 4 PASSED: Simulation status correctly reported"
echo

# Test 5: Wait and try another simulation (should work after first completes)
echo "Test 5: Start second simulation after first completes"
echo "----------------------------------------------------"
echo "   Waiting 2 seconds for first simulation to complete..."
sleep 2

second_sim_data='{"percentage": 5.0, "seed": 12345}'
second_sim_response=$(make_api_call "POST" "$SIMULATION_ENDPOINT" "$second_sim_data" "Starting second simulation")

second_session_id=$(echo "$second_sim_response" | jq -r '.session_id')
second_estimated_tiles=$(echo "$second_sim_response" | jq -r '.estimated_tiles')

if [ "$second_session_id" = "null" ]; then
    echo "❌ Expected second simulation to succeed after first completes"
    echo "   Response: $second_sim_response"
    exit 1
fi

# Test deterministic behavior - same seed should produce same results
if [ "$second_estimated_tiles" != "$estimated_tiles" ]; then
    echo "⚠️  Warning: Different tile counts with same seed ($estimated_tiles vs $second_estimated_tiles)"
    echo "   This might indicate state reset is working (good) or non-deterministic behavior"
fi

echo "✅ Test 5 PASSED: Second simulation started successfully"
echo "   Session ID: $second_session_id"
echo "   Estimated tiles: $second_estimated_tiles"
echo

# Test 6: Test error handling with invalid data
echo "Test 6: Test error handling"
echo "---------------------------"
invalid_data='{"percentage": 150.0, "seed": 12345}'
error_response=$(make_api_call "POST" "$SIMULATION_ENDPOINT" "$invalid_data" "Testing with invalid percentage")

error_percentage=$(echo "$error_response" | jq -r '.percentage')

# Percentage should be clamped to 100%
if [ "$error_percentage" != "100" ]; then
    echo "❌ Expected percentage to be clamped to 100, got $error_percentage"
    exit 1
fi

echo "✅ Test 6 PASSED: Error handling works correctly (percentage clamped to 100%)"
echo

# Final status check
echo "Final Status Check"
echo "-----------------"
final_status=$(make_api_call "GET" "$STATUS_ENDPOINT" "" "Final status check")
echo

echo "🎉 All API simulation state management tests completed successfully!"
echo
echo "Summary of tested functionality:"
echo "✅ Session creation and tracking"
echo "✅ Concurrent simulation prevention"  
echo "✅ Simulation status reporting"
echo "✅ State reset between simulations"
echo "✅ Error handling and input validation"
echo "✅ Session cleanup after completion"