-- =====================================================================
-- 032 ROLLBACK -- Obligation Composite dispatcher
--
-- Reverses database/032_obligation_composite_dispatcher.sql.
--
-- Drops:
--   * dbo.cm_manage_obligation_composite
--   * dbo.fn_cm_obligation_type_entity
--
-- SAFETY GATE
-- -----------
-- If any PENDING bundle emitted by this dispatcher still exists, dropping
-- the proc is safe for the bundle itself (031's approve routine applies
-- rows via cm_manage_repository / cm_manage_obligation_taxonomy, NOT via
-- this proc), but the maker would no longer be able to submit new
-- composite saves.  We warn so the operator makes that call knowingly.
--
-- This rollback does NOT touch 031 (bundle infrastructure) -- run
-- 031_change_management_bundle_rollback.sql separately if that is also
-- being reverted, and run it AFTER this one.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @pending_bundles INT = 0;

IF COL_LENGTH('GRAC_New.change_management','bundle_id') IS NOT NULL
    SET @pending_bundles = (
        SELECT COUNT(DISTINCT bundle_id)
        FROM GRAC_New.change_management
        WHERE bundle_id IS NOT NULL
          AND status = N'Pending Approval'
          AND module_name = N'obligations');

IF @pending_bundles > 0
BEGIN
    PRINT '---------------------------------------------------------------';
    PRINT 'NOTICE: pending obligation bundles exist.';
    PRINT '';
    PRINT 'Pending bundle count:';
    PRINT CONVERT(NVARCHAR(20), @pending_bundles);
    PRINT '';
    PRINT 'Those bundles remain APPROVABLE after this rollback -- 031 applies';
    PRINT 'them through cm_manage_repository / cm_manage_obligation_taxonomy,';
    PRINT 'not through the proc being dropped here.';
    PRINT '';
    PRINT 'What DOES stop working: makers can no longer submit new composite';
    PRINT 'saves, so the merged Obligation page must be reverted to the split';
    PRINT 'Master + Type Details pages in the same release.';
    PRINT '';
    PRINT 'To inspect them:';
    PRINT '  EXEC dbo.sp_cm_change_bundle_list @p_status = N''Pending Approval'';';
    PRINT '---------------------------------------------------------------';
END
GO

IF OBJECT_ID('dbo.cm_manage_obligation_composite','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_manage_obligation_composite;
GO

IF OBJECT_ID('dbo.fn_cm_obligation_type_entity','FN') IS NOT NULL
    DROP FUNCTION dbo.fn_cm_obligation_type_entity;
GO

PRINT '032 rollback complete. cm_manage_obligation_composite removed.';
PRINT 'The legacy ''obligations'' entity type was never modified and is unaffected.';
GO
