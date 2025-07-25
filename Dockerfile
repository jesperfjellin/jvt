# Multi-stage build for the Rust tile worker
FROM rust:1.88.0-bookworm as builder

WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src/ ./src/

# Build the application
RUN cargo build --release

# Runtime image with minimal dependencies
FROM ubuntu:24.04

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    postgresql-client \
    osmosis \
    osmctools \
    osm2pgsql \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create directories as specified in development.yaml
RUN mkdir -p /var/cache/renderd \
    && mkdir -p /var/lib/pmtiles \
    && mkdir -p /var/log/tiles

# Create non-root user for running the application
RUN useradd -m -u 1001 -s /bin/bash tiles || echo "User already exists"
RUN chown -R tiles:tiles /var/cache/renderd /var/lib/pmtiles /var/log/tiles

# Copy the built binary
COPY --from=builder /app/target/release/jvt /usr/local/bin/jvt

# Copy scripts
COPY scripts/ /usr/local/bin/

USER tiles
WORKDIR /home/tiles

CMD ["/usr/local/bin/jvt"] 