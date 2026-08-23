-- =====================================================================
-- 027 Obligation Taxonomy migration -- ROLLBACK
--
-- Reverses the DATA effects of 027_obligation_taxonomy_migration.sql
-- without touching schema.  Run BEFORE 026_..._rollback if you want to
-- fully tear down the taxonomy (026 rollback drops obligation_type_id
-- and will fail if rows still reference obligation_type_master).
--
-- Idempotent -- uses entered_by = 'migration-027' as the tag for rows
-- we own; SME-authored rows are left alone.
--
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------
-- 1. Remove Retention specs seeded by 027.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_retention_spec','U') IS NOT NULL
BEGIN
    DELETE FROM GRAC_New.obligation_retention_spec
    WHERE entered_by = N'migration-027';
END
GO

-- ---------------------------------------------------------------------
-- 2. Remove Execution evidence links created by 027.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_execution_evidence_link','U') IS NOT NULL
BEGIN
    DELETE FROM GRAC_New.obligation_execution_evidence_link
    WHERE entered_by = N'migration-027';
END
GO

-- ---------------------------------------------------------------------
-- 3. Clear obligation_type_id on rows that 027 classified as Execution.
--    Only rows we tagged via updated_by = 'migration-027' are cleared;
--    rows re-classified after 027 by SMEs are left alone (heuristic:
--    if updated_by later got overwritten by someone else, we cannot
--    tell -- caller should reconcile manually).
-- ---------------------------------------------------------------------
IF COL_LENGTH('GRAC_New.requirement_obligation','obligation_type_id') IS NOT NULL
BEGIN
    UPDATE GRAC_New.requirement_obligation
    SET obligation_type_id = NULL,
        updated_by = N'migration-027-rollback',
        updated_dt = SYSUTCDATETIME()
    WHERE obligation_type_id IS NOT NULL
      AND updated_by = N'migration-027';
END
GO

-- ---------------------------------------------------------------------
-- 4. Remove seeded obligation_type_master rows.
--    Guarded so we skip deletion if any requirement_obligation still
--    references a type (either SME work, or 3 above's heuristic missed
--    something).  Caller must reconcile before final tear-down.
-- ---------------------------------------------------------------------
IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NOT NULL
BEGIN
    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation
        WHERE obligation_type_id IS NOT NULL
    )
    BEGIN
        DELETE FROM GRAC_New.obligation_type_master
        WHERE entered_by = N'migration-027'
           OR updated_by = N'migration-027';
    END
    ELSE
    BEGIN
        PRINT '027 rollback WARNING: requirement_obligation rows still carry obligation_type_id.  obligation_type_master rows left in place.  Clear references (or run this rollback again after reclassification) before dropping schema.';
    END
END
GO

PRINT '027 obligation taxonomy migration rollback complete.';
GO
