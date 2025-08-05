/***********************************************************************
  02-synthetic-triggers.sql
  ----------------------------------------------------------------------
  Change-detection triggers for the synthetic JVT schema.
  • A single PL/pgSQL function (`track_synthetic_changes`) is attached to
    the three demo tables.
  • One *unprocessed* row per (z,x,y) tile is kept in `changed_tiles`
    regardless of how many DML events hit that tile.  If the same tile
    changes again before the worker processes it, we just “bump” the
    row’s timestamp and clear `processed_at`.
***********************************************************************/

-----------------------------------------------------------------------
--  Ensure we have ONE unconditional UNIQUE index on (z,x,y)
--  (the old partial-unique index on processed_at is now obsolete)
-----------------------------------------------------------------------
DROP INDEX IF EXISTS changed_tiles_z_x_y_unprocessed_unique;
CREATE UNIQUE INDEX IF NOT EXISTS changed_tiles_zxy_unique
ON changed_tiles (z, x, y);

-----------------------------------------------------------------------
--  Change-tracking function
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION track_synthetic_changes()
RETURNS TRIGGER AS $$
DECLARE
    geom_to_process GEOMETRY;
    table_name      TEXT;
    operation_type  TEXT;
    tiles_affected  INT := 0;
BEGIN
    -- identify source table & operation
    table_name     := TG_TABLE_NAME;
    operation_type := TG_OP;

    -- which geometry to inspect?
    IF TG_OP = 'DELETE' THEN
        geom_to_process := OLD.geom;
    ELSE
        geom_to_process := NEW.geom;
    END IF;

    IF geom_to_process IS NOT NULL THEN
        ----------------------------------------------------------------
        --  UPSERT each affected tile into changed_tiles
        ----------------------------------------------------------------
        INSERT INTO changed_tiles (z, x, y,
                                   source_table, operation,
                                   changed_at,    processed_at)
        SELECT  t.z, t.x, t.y,
                table_name, operation_type,
                NOW(),      NULL                 -- mark as “pending”
        FROM   calculate_affected_tiles_synthetic(geom_to_process, 8, 8) AS t
        ON CONFLICT (z, x, y)               -- same tile already queued
        DO UPDATE
           SET changed_at   = EXCLUDED.changed_at,   -- bump timestamp
               source_table = EXCLUDED.source_table,
               operation    = EXCLUDED.operation,
               processed_at = NULL;                  -- ensure pending

        GET DIAGNOSTICS tiles_affected = ROW_COUNT;

        -- send NOTIFY for the Rust worker (optional, still nice to have)
        PERFORM pg_notify(
            'tiles_updated',
            json_build_object(
                'table',      table_name,
                'operation',  operation_type,
                'tile_count', tiles_affected,
                'timestamp',  extract(epoch FROM now())
            )::TEXT
        );

        RAISE DEBUG 'Synthetic change: % % affected % tiles',
                    operation_type, table_name, tiles_affected;
    END IF;

    -- return the correct row for the DML operation
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql;

-----------------------------------------------------------------------
--  Attach the trigger to each synthetic layer
-----------------------------------------------------------------------
DROP TRIGGER IF EXISTS demo_points_changes   ON demo_points;
DROP TRIGGER IF EXISTS demo_lines_changes    ON demo_lines;
DROP TRIGGER IF EXISTS demo_polygons_changes ON demo_polygons;

CREATE TRIGGER demo_points_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_points
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

CREATE TRIGGER demo_lines_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_lines
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

CREATE TRIGGER demo_polygons_changes
    AFTER INSERT OR UPDATE OR DELETE ON demo_polygons
    FOR EACH ROW EXECUTE FUNCTION track_synthetic_changes();

-----------------------------------------------------------------------
--  reset_synthetic_demo(): quick wipe of all demo data (unchanged)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reset_synthetic_demo()
RETURNS VOID AS $$
BEGIN
    TRUNCATE TABLE demo_points    CASCADE;
    TRUNCATE TABLE demo_lines     CASCADE;
    TRUNCATE TABLE demo_polygons  CASCADE;
    TRUNCATE TABLE changed_tiles  CASCADE;
    TRUNCATE TABLE changed_tile_batches CASCADE;

    ALTER SEQUENCE demo_points_id_seq         RESTART WITH 1;
    ALTER SEQUENCE demo_lines_id_seq          RESTART WITH 1;
    ALTER SEQUENCE demo_polygons_id_seq       RESTART WITH 1;
    ALTER SEQUENCE changed_tiles_id_seq       RESTART WITH 1;
    ALTER SEQUENCE changed_tile_batches_id_seq RESTART WITH 1;

    RAISE NOTICE 'Synthetic demo data reset complete';
END;
$$ LANGUAGE plpgsql;

-----------------------------------------------------------------------
--  generate_tile_test_data(): helper for ad-hoc inserts (unchanged)
-----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generate_tile_test_data(
    tile_x           INT,
    tile_y           INT,
    tile_z           INT DEFAULT 8,
    points_per_tile  INT DEFAULT 2
) RETURNS VOID AS $$
DECLARE
    tile_bounds     GEOMETRY;
    center_point    GEOMETRY;
    random_point    GEOMETRY;
    random_line     GEOMETRY;
    random_polygon  GEOMETRY;
    i               INT;
BEGIN
    tile_bounds  := ST_TileEnvelope(tile_z, tile_x, tile_y);
    center_point := ST_Centroid(tile_bounds);

    -- Points
    FOR i IN 1..points_per_tile LOOP
        random_point := ST_SetSRID(
            ST_MakePoint(
                ST_XMin(tile_bounds) + random() * (ST_XMax(tile_bounds)-ST_XMin(tile_bounds)),
                ST_YMin(tile_bounds) + random() * (ST_YMax(tile_bounds)-ST_YMin(tile_bounds))
            ), 3857);
        INSERT INTO demo_points (geom, demo_tag)
        VALUES (random_point,
                format('tile_%s_%s_point_%s', tile_x, tile_y, i));
    END LOOP;

    -- Line
    random_line := ST_MakeLine(
        ST_Translate(center_point, -5000, -5000),
        ST_Translate(center_point,  5000,  5000));
    INSERT INTO demo_lines (geom, demo_tag)
    VALUES (random_line, format('tile_%s_%s_line', tile_x, tile_y));

    -- Polygon
    random_polygon := ST_Buffer(center_point, 3000);
    INSERT INTO demo_polygons (geom, demo_tag)
    VALUES (random_polygon,
            format('tile_%s_%s_polygon', tile_x, tile_y));
END;
$$ LANGUAGE plpgsql;

-----------------------------------------------------------------------
--  Initialise NOTIFY channel (unchanged)
-----------------------------------------------------------------------
LISTEN tiles_updated;
