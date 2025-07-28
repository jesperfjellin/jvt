import React from 'react'
import Map from './components/Map'
import './App.css'

function App() {
  return (
    <div className="app">
      <header className="app-header">
        <h1>JVT - Incremental Vector Tiles</h1>
        <p>Live OpenStreetMap vector tiles with minutely updates</p>
      </header>
      <main className="app-main">
        <Map />
      </main>
    </div>
  )
}

export default App 