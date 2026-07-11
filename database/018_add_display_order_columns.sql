/*
  GRAC Repository Management - Part 018
  Add display_order columns to authority, artifact, release so the SAVE branches
  in cm_manage_repository can auto-assign ISNULL(MAX(display_order),0)+1 within
  the correct parent/context scope.  Existing rows are back-filled in
  entered_dt order so the historical sequence is preserved.

  Safe to re-run.  Each ALTER and backfill block is guarded.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51601, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;
GO

/* authority.display_order ---------------------------------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.authority') AND name = 'display_order')
BEGIN
    ALTER TABLE GRAC_New.authority
        ADD display_order INT NOT NULL
            CONSTRAINT df_cm_authority_display_order DEFAULT 0;
END
GO

;WITH ordered AS (
    SELECT authority_id,
           ROW_NUMBER() OVER (ORDER BY entered_dt, authority_id) rn
    FROM GRAC_New.authority
    WHERE display_order = 0
)
UPDATE a
SET a.display_order = o.rn
FROM GRAC_New.authority a
JOIN ordered o ON o.authority_id = a.authority_id;
GO

/* artifact.display_order (scoped by authority_id) --------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.artifact') AND name = 'display_order')
BEGIN
    ALTER TABLE GRAC_New.artifact
        ADD display_order INT NOT NULL
            CONSTRAINT df_cm_artifact_display_order DEFAULT 0;
END
GO

;WITH ordered AS (
    SELECT artifact_id,
           ROW_NUMBER() OVER (PARTITION BY authority_id ORDER BY entered_dt, artifact_id) rn
    FROM GRAC_New.artifact
    WHERE display_order = 0
)
UPDATE a
SET a.display_order = o.rn
FROM GRAC_New.artifact a
JOIN ordered o ON o.artifact_id = a.artifact_id;
GO

/* release.display_order (scoped by artifact_id) ----------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.release') AND name = 'display_order')
BEGIN
    ALTER TABLE GRAC_New.release
        ADD display_order INT NOT NULL
            CONSTRAINT df_cm_release_display_order DEFAULT 0;
END
GO

;WITH ordered AS (
    SELECT release_id,
           ROW_NUMBER() OVER (PARTITION BY artifact_id ORDER BY entered_dt, release_id) rn
    FROM GRAC_New.release
    WHERE display_order = 0
)
UPDATE r
SET r.display_order = o.rn
FROM GRAC_New.release r
JOIN ordered o ON o.release_id = r.release_id;
GO

/* source_structure_node and framework_statement already carry display_order
   (since 001_control_management_schema.sql).  Existing rows may have 0 from
   the original DEFAULT - back-fill them in the parent-scoped sequence the
   new SP logic expects. */

;WITH ordered AS (
    SELECT structure_node_id,
           ROW_NUMBER() OVER (
               PARTITION BY release_id, ISNULL(parent_node_id, -1)
               ORDER BY entered_dt, structure_node_id) rn
    FROM GRAC_New.source_structure_node
    WHERE display_order = 0
)
UPDATE n
SET n.display_order = o.rn
FROM GRAC_New.source_structure_node n
JOIN ordered o ON o.structure_node_id = n.structure_node_id;
GO

;WITH ordered AS (
    SELECT framework_statement_id,
           ROW_NUMBER() OVER (
               PARTITION BY structure_node_id
               ORDER BY entered_dt, framework_statement_id) rn
    FROM GRAC_New.framework_statement
    WHERE display_order = 0
)
UPDATE f
SET f.display_order = o.rn
FROM GRAC_New.framework_statement f
JOIN ordered o ON o.framework_statement_id = f.framework_statement_id;
GO

PRINT 'Migration 018 complete. authority/artifact/release have display_order columns and all five entities have parent-scoped sequences back-filled.';
GO
