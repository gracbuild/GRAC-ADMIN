/*
================================================================================
  Migration : 023 - Keywords on Obligation Master and Practice (Requirement)
  Purpose   : Support the "duplicate/similar records" helper on
                * Obligation Master (Repository -> obligations)
                * Practices        (Repository -> requirements)
              Keywords are captured as a comma-separated NVARCHAR(MAX) column
              on each master.  A future migration can normalize into
              *_keyword tables (mirroring control_keyword) - the read path in
              the SP already returns a plain "Keywords" string so the
              front-end contract will not change.
  Rules     :
    * Backward compatible - column added NULLable, no default.
    * Idempotent           - guarded by COL_LENGTH() so re-runs are safe.
    * No physical delete   - unchanged (masters remain soft-delete).
    * All edits flow through cm_manage_repository (maker-checker aware).
  Depends on: 001 (schema), 002 (procedures), 019/020 (obligation master).
================================================================================
*/
SET NOCOUNT ON;
GO

/*----------------------------------------------------------------------------
  1) Obligation Master keywords
     Table: GRAC_New.requirement_obligation  (post-020 renamed obligation master)
----------------------------------------------------------------------------*/
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
   AND COL_LENGTH('GRAC_New.requirement_obligation','keywords') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement_obligation
        ADD keywords NVARCHAR(MAX) NULL;
END
GO

/*----------------------------------------------------------------------------
  2) Practice (Requirement) keywords
     Table: GRAC_New.requirement
----------------------------------------------------------------------------*/
IF OBJECT_ID('GRAC_New.requirement','U') IS NOT NULL
   AND COL_LENGTH('GRAC_New.requirement','keywords') IS NULL
BEGIN
    ALTER TABLE GRAC_New.requirement
        ADD keywords NVARCHAR(MAX) NULL;
END
GO

/*----------------------------------------------------------------------------
  3) Search-friendly index hint (nullable, non-unique).
     Full-text is not enabled on all environments; a plain non-clustered
     helper index on the first 400 chars keeps LIKE '%keyword%' cheap
     enough for the "similar records" 10-row TOP query.
----------------------------------------------------------------------------*/
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
   AND NOT EXISTS(
        SELECT 1 FROM sys.indexes
        WHERE name='ix_cm_requirement_obligation_status_keywords'
          AND object_id=OBJECT_ID('GRAC_New.requirement_obligation'))
BEGIN
    -- Include keywords so the "similar" scan stays index-covered even when
    -- the caller filters by status='Active' first.  We do not index the
    -- NVARCHAR(MAX) itself (unsupported); the INCLUDE gets us covered reads.
    CREATE NONCLUSTERED INDEX ix_cm_requirement_obligation_status_keywords
        ON GRAC_New.requirement_obligation(status)
        INCLUDE(obligation_name, obligation_text, execution_frequency_id, retention_requirement);
END
GO

IF OBJECT_ID('GRAC_New.requirement','U') IS NOT NULL
   AND NOT EXISTS(
        SELECT 1 FROM sys.indexes
        WHERE name='ix_cm_requirement_status_keywords'
          AND object_id=OBJECT_ID('GRAC_New.requirement'))
BEGIN
    CREATE NONCLUSTERED INDEX ix_cm_requirement_status_keywords
        ON GRAC_New.requirement(status)
        INCLUDE(requirement_code, requirement_name, requirement_statement);
END
GO

/*----------------------------------------------------------------------------
  4) Defensively drop the stale unique indexes that migration 019 retired.
     Migration 002 (procedure facade) historically re-created these on every
     deploy; that resurrection made the second APPROVE of a master Obligation
     fail with "A record with the same unique value already exists." because
     both requirement_id and release_id are NULL on master rows and SQL Server
     treats NULLs as equal in a UNIQUE index.
----------------------------------------------------------------------------*/
IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
   AND EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_requirement_obligation_release_active'
                AND object_id=OBJECT_ID('GRAC_New.requirement_obligation'))
BEGIN
    DROP INDEX ux_cm_requirement_obligation_release_active
        ON GRAC_New.requirement_obligation;
    PRINT '  - Dropped stale index ux_cm_requirement_obligation_release_active.';
END
GO

IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
   AND EXISTS(SELECT 1 FROM sys.indexes
              WHERE name='ux_cm_requirement_obligation_evidence_active'
                AND object_id=OBJECT_ID('GRAC_New.requirement_obligation_evidence'))
BEGIN
    DROP INDEX ux_cm_requirement_obligation_evidence_active
        ON GRAC_New.requirement_obligation_evidence;
    PRINT '  - Dropped stale index ux_cm_requirement_obligation_evidence_active.';
END
GO

PRINT 'Migration 023 completed: keywords column added to Obligation Master and Practice.';
GO
