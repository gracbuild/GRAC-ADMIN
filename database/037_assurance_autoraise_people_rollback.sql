-- =====================================================================
-- 037 ROLLBACK -- Event-driven Assurance, Phase C auto-raise
--
-- Reverses database/037_assurance_autoraise_people.sql:
--
--   1. Drop GRAC_New.tr_cm_user_assurance_autoraise
--   2. Retire the 'people-autoraise' setting
--
-- No safety gate is needed.  Dropping the trigger stops FUTURE auto-raises;
-- occurrences and checklists already raised are untouched and remain fully
-- usable through the Event Checklists screens.  Events can still be raised
-- manually via Raise Event.
--
-- BEFORE DROPPING, CONSIDER THE OFF SWITCH INSTEAD
-- ------------------------------------------------
-- If the goal is simply to stop auto-raising, prefer:
--
--   UPDATE GRAC_New.reference_option SET status = 'Inactive'
--   WHERE option_group = 'assurance-settings'
--     AND option_value = 'people-autoraise';
--
-- That is reversible in one statement and leaves the trigger in place, so
-- re-enabling does not require re-running a migration.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- Report what auto-raise produced, so the operator knows what is being
-- orphaned from its source before the hook disappears.
DECLARE @auto_raised INT = 0;

IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NOT NULL
    SET @auto_raised = (
        SELECT COUNT(1) FROM GRAC_New.assurance_event_occurrence
        WHERE raise_source = N'System');

IF @auto_raised > 0
BEGIN
    PRINT '---------------------------------------------------------------';
    PRINT 'NOTICE: system-raised occurrences exist.';
    PRINT '';
    PRINT 'Auto-raised occurrence count:';
    PRINT CONVERT(NVARCHAR(20), @auto_raised);
    PRINT '';
    PRINT 'These are NOT removed by this rollback -- they remain visible and';
    PRINT 'completable in Event Checklists.  Only future auto-raising stops.';
    PRINT '';
    PRINT 'To review them:';
    PRINT '  SELECT o.occurrence_id, e.event_code, o.subject_label,';
    PRINT '         o.occurred_dt, o.status';
    PRINT '  FROM GRAC_New.assurance_event_occurrence o';
    PRINT '  JOIN GRAC_New.event_type_master e ON e.event_type_id = o.event_type_id';
    PRINT '  WHERE o.raise_source = ''System''';
    PRINT '  ORDER BY o.occurred_dt DESC;';
    PRINT '---------------------------------------------------------------';
END
GO

IF OBJECT_ID('GRAC_New.tr_cm_user_assurance_autoraise','TR') IS NOT NULL
    DROP TRIGGER GRAC_New.tr_cm_user_assurance_autoraise;
GO

-- fn_cm_assurance_specs_for_event is NOT dropped here.
-- 037 re-emitted sp_cm_assurance_occurrence_raise to depend on it, so
-- dropping the function would break the manual raise path that this rollback
-- is meant to leave working.  To remove the function as well, first re-run
-- 036_assurance_runtime_procs.sql (which restores the inline-join version of
-- the proc), then drop it:
--     DROP FUNCTION GRAC_New.fn_cm_assurance_specs_for_event;
GO

UPDATE GRAC_New.reference_option
SET status = N'Inactive', updated_by = 'rollback-037', updated_dt = SYSUTCDATETIME()
WHERE option_group = N'assurance-settings'
  AND option_value = N'people-autoraise';
GO

PRINT '037 rollback complete.';
PRINT '  Auto-raise trigger dropped; the setting is retired (not deleted).';
PRINT '  Existing occurrences and checklists are untouched.';
PRINT '  Events can still be raised manually from Event Checklists.';
GO
