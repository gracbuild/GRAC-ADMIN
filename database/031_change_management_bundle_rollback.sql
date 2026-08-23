-- =====================================================================
-- 031 ROLLBACK -- Change Management: atomic approval bundles
--
-- Reverses database/031_change_management_bundle.sql.
--
-- Order matters:
--   1. Drop the procedures (no dependencies on them outside Phase 2+).
--   2. Drop the filtered index.
--   3. Drop bundle_seq / bundle_id columns -- ONLY if no row is using them.
--
-- SAFETY GATE
-- -----------
-- If any change_management row still carries a bundle_id, dropping the
-- column would silently destroy the grouping that ties a multi-row
-- approval together, leaving orphaned per-sub-entity rows that a checker
-- could then partially approve.  This script therefore REFUSES to drop
-- the columns while bundled rows exist and tells the operator what to do.
--
-- To force the drop you must first resolve or purge the bundled rows --
-- deliberately a manual step, not something a rollback should decide.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- =====================================================================
-- 1. Procedures.
-- =====================================================================
IF OBJECT_ID('dbo.sp_cm_change_bundle_list','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_change_bundle_list;
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_send_back','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_change_bundle_send_back;
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_reject','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_change_bundle_reject;
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_approve','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_change_bundle_approve;
GO

IF OBJECT_ID('dbo.sp_cm_change_bundle_apply_row','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_change_bundle_apply_row;
GO

-- =====================================================================
-- 2. Index.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'ix_cm_change_management_bundle'
             AND object_id = OBJECT_ID('GRAC_New.change_management'))
BEGIN
    DROP INDEX ix_cm_change_management_bundle ON GRAC_New.change_management;
END
GO

-- =====================================================================
-- 3. Columns -- gated on there being no bundled rows left.
-- =====================================================================
DECLARE @bundled_rows BIGINT = 0;

IF COL_LENGTH('GRAC_New.change_management','bundle_id') IS NOT NULL
    SET @bundled_rows =
        (SELECT COUNT_BIG(1) FROM GRAC_New.change_management WHERE bundle_id IS NOT NULL);

IF @bundled_rows > 0
BEGIN
    PRINT '---------------------------------------------------------------';
    PRINT 'ROLLBACK HALTED: change_management still has bundled rows.';
    PRINT 'Dropping bundle_id would orphan them and allow partial approval.';
    PRINT '';
    PRINT 'Bundled row count:';
    PRINT CONVERT(NVARCHAR(20), @bundled_rows);
    PRINT '';
    PRINT 'Resolve them first, then re-run this script.  For example:';
    PRINT '  -- inspect';
    PRINT '  SELECT bundle_id, COUNT(1) rows_in_bundle, MAX(status) status';
    PRINT '  FROM GRAC_New.change_management';
    PRINT '  WHERE bundle_id IS NOT NULL GROUP BY bundle_id;';
    PRINT '';
    PRINT '  -- then either action the pending bundles through the checker UI,';
    PRINT '  -- or (non-production only) clear the grouping:';
    PRINT '  -- UPDATE GRAC_New.change_management';
    PRINT '  -- SET bundle_id = NULL, bundle_seq = NULL WHERE bundle_id IS NOT NULL;';
    PRINT '---------------------------------------------------------------';
    PRINT 'Procedures and index WERE dropped.  Columns were left in place.';
END
ELSE
BEGIN
    IF COL_LENGTH('GRAC_New.change_management','bundle_seq') IS NOT NULL
        ALTER TABLE GRAC_New.change_management DROP COLUMN bundle_seq;

    IF COL_LENGTH('GRAC_New.change_management','bundle_id') IS NOT NULL
        ALTER TABLE GRAC_New.change_management DROP COLUMN bundle_id;

    PRINT '031 rollback complete. Procedures, index, and columns removed.';
END
GO
