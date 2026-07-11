/*
  GRAC Repository Management - Part 021
  Extend the Obligation Mapping table so a mapping carries the originating
  Framework Statement, which is the cell the Requirement-first UI maps an
  Obligation against:
      Requirement -> [Framework Statements via framework_statement_requirement_map]
                  -> [Releases]   -> (matrix row)
                                  -> Obligation

  Effective shape after this migration:

    obligation_requirement_release_map
      obligation_map_id            BIGINT IDENTITY PK
      obligation_id                BIGINT FK requirement_obligation
      requirement_id               BIGINT FK requirement
      release_id                   BIGINT FK release
      framework_statement_id       BIGINT NULL FK framework_statement   (NEW)
      status, audit columns
      UNIQUE (requirement_id, release_id, framework_statement_id, obligation_id) WHERE status='Active'

  Old unique constraint on (obligation_id, requirement_id, release_id) is
  dropped because the same Obligation may now legitimately appear on different
  Statements within the same Requirement+Release.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51901, 'Schema GRAC_New is missing. Run earlier migrations first.', 1;

IF OBJECT_ID('GRAC_New.obligation_requirement_release_map','U') IS NULL
    THROW 51902, 'obligation_requirement_release_map does not exist. Run migration 019 first.', 1;
GO

/* 1. Add framework_statement_id ----------------------------------------- */
IF NOT EXISTS(SELECT 1 FROM sys.columns
              WHERE object_id = OBJECT_ID('GRAC_New.obligation_requirement_release_map')
                AND name = 'framework_statement_id')
BEGIN
    ALTER TABLE GRAC_New.obligation_requirement_release_map
        ADD framework_statement_id BIGINT NULL
            CONSTRAINT fk_cm_obligation_map_statement
                REFERENCES GRAC_New.framework_statement(framework_statement_id);
END
GO

/* 2. Drop the old 3-column uniqueness if it is still present ------------ */
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'uq_cm_obligation_map_active'
      AND object_id = OBJECT_ID('GRAC_New.obligation_requirement_release_map'))
BEGIN
    -- The constraint was created as UNIQUE in 019; both UNIQUE constraints and
    -- regular indexes are listed in sys.indexes.  Drop whichever flavour we have.
    IF EXISTS (
        SELECT 1 FROM sys.objects
        WHERE name = 'uq_cm_obligation_map_active' AND type = 'UQ')
        ALTER TABLE GRAC_New.obligation_requirement_release_map
            DROP CONSTRAINT uq_cm_obligation_map_active;
    ELSE
        DROP INDEX uq_cm_obligation_map_active
            ON GRAC_New.obligation_requirement_release_map;
END
GO

/* 3. Filtered unique index on the new 4-tuple --------------------------- */
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'uq_cm_obligation_map_req_rel_stmt_obl'
      AND object_id = OBJECT_ID('GRAC_New.obligation_requirement_release_map'))
BEGIN
    -- ISNULL handling: filtered unique indexes treat NULLs as equal in a
    -- somewhat unintuitive way.  We allow framework_statement_id = NULL for
    -- statement-less mappings created prior to this migration; the index
    -- still enforces uniqueness of (req, rel, stmt, obl) for active rows.
    CREATE UNIQUE INDEX uq_cm_obligation_map_req_rel_stmt_obl
        ON GRAC_New.obligation_requirement_release_map (
            requirement_id, release_id, framework_statement_id, obligation_id)
        WHERE status = 'Active';
END
GO

/* 4. Supporting non-unique index for the Requirement-first matrix lookup -- */
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_cm_obligation_map_req_lookup'
      AND object_id = OBJECT_ID('GRAC_New.obligation_requirement_release_map'))
BEGIN
    CREATE INDEX ix_cm_obligation_map_req_lookup
        ON GRAC_New.obligation_requirement_release_map (
            requirement_id, status)
        INCLUDE (release_id, framework_statement_id, obligation_id);
END
GO

PRINT 'Migration 021 complete. obligation_requirement_release_map now keyed on (req, rel, stmt, obl).';
GO
