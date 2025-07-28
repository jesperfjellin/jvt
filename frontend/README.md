# JVT Frontend

React + TypeScript frontend for the JVT (Incremental Vector Tiles) project.

## Features

- **MapLibre GL JS**: High-performance map rendering
- **React 18**: Modern React with hooks and concurrent features
- **TypeScript**: Type-safe development
- **Vite**: Fast development and building

## Development

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

## Map Configuration

The map is currently centered on Oslo, Norway and uses OpenStreetMap raster tiles as a temporary base layer. Eventually this will be replaced with:

- PMTiles vector tiles from the Rust backend
- Heat map overlay showing tile update frequency
- Custom styling for the vector data

## Project Structure

```
src/
├── components/
│   ├── Map.tsx          # MapLibre GL map component
│   └── Map.css          # Map-specific styles
├── App.tsx              # Main application component
├── App.css              # Application styles
├── main.tsx             # React entry point
└── index.css            # Global styles
```

## Environment

The frontend is designed to run in Docker alongside the Rust backend and PostgreSQL database. See the main project `docker-compose.yml` for the complete setup. 