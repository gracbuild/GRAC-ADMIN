-- =====================================================================
-- 056 rollback -- Obligation Master: Source Statement mapping
--
-- Removes what 056 ADDED:
--   * dbo.cm_get_obligation_statement_map
--   * GRAC_New.obligation_framework_statement_map (and its index)
--
-- Does NOT restore cm_manage_repository / cm_manage_obligation_composite.
-- Both are CREATE OR ALTER re-emissions and this script cannot know which
-- definition preceded them, so restoring them is a deliberate second step:
--
--     re-run database/055_obligation_description_field.sql
--
-- Run that BEFORE this script.  Dropping the table while the 056 version of
-- cm_manage_repository is still installed leaves the 'obligations' save
-- branch referencing a table that no longer exists, and every obligation
-- save fails -- but only for callers that send sourceStatements, which
-- makes it an intermittent failure rather than an obvious one.
--
-- Data loss: the obligation <-> statement mappings are deleted, not
-- deactivated.  There is nowhere else that fact is recorded.  Take a copy
-- first if the mappings might be wanted back:
--
--     SELECT * INTO GRAC_New.zz_056_backup_obligation_statement_map
--     FROM GRAC_New.obligation_framework_statement_map;
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('dbo.cm_get_obligation_statement_map','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_get_obligation_statement_map;
GO

IF EXISTS(SELECT 1 FROM sys.indexes
          WHERE name = 'ix_cm_obligation_statement_lookup'
            AND object_id = OBJECT_ID('GRAC_New.obligation_framework_statement_map'))
    DROP INDEX ix_cm_obligation_statement_lookup
        ON GRAC_New.obligation_framework_statement_map;
GO

IF OBJECT_ID('GRAC_New.obligation_framework_statement_map','U') IS NOT NULL
    DROP TABLE GRAC_New.obligation_framework_statement_map;
GO

PRINT '056 rollback complete.';
PRINT '  Dropped: GRAC_New.obligation_framework_statement_map, dbo.cm_get_obligation_statement_map.';
PRINT '  Re-run 055_obligation_description_field.sql to restore cm_manage_repository';
PRINT '  and cm_manage_obligation_composite if that has not been done already.';
GO
