-- =====================================================================
-- 035 ROLLBACK -- Event-driven Assurance, Phase B runtime schema
--
-- Reverses database/035_assurance_runtime_schema.sql.
--
-- Order (children first, FKs demand it):
--   1. assurance_checklist_evidence
--   2. assurance_checklist_item
--   3. assurance_event_occurrence
--   4. menu row + role permissions
--   5. cm_entity_master rows
--
-- Run 036's rollback FIRST so no procedure is left referencing these tables.
--
-- SAFETY GATE
-- -----------
-- These tables hold OPERATIONAL COMPLIANCE RECORDS -- evidence that an
-- assurance was actually carried out for a real person or asset.  Unlike a
-- definition table, this data cannot be re-derived: dropping it destroys the
-- audit trail permanently.  The script refuses while any occurrence exists.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @occurrences INT = 0, @completed INT = 0;

IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NOT NULL
    SET @occurrences = (SELECT COUNT(1) FROM GRAC_New.assurance_event_occurrence);

IF OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NOT NULL
    SET @completed = (SELECT COUNT(1) FROM GRAC_New.assurance_checklist_item WHERE status = 'Completed');

IF @occurrences > 0
BEGIN
    PRINT '---------------------------------------------------------------';
    PRINT 'ROLLBACK HALTED: assurance occurrences exist.';
    PRINT '';
    PRINT 'Occurrence count:';
    PRINT CONVERT(NVARCHAR(20), @occurrences);
    PRINT 'Completed checklist items:';
    PRINT CONVERT(NVARCHAR(20), @completed);
    PRINT '';
    PRINT 'This is operational compliance evidence -- proof that an assurance';
    PRINT 'was performed for a real subject.  It cannot be regenerated from';
    PRINT 'the definition tables.  Dropping it destroys the audit trail.';
    PRINT '';
    PRINT 'Export before proceeding:';
    PRINT '  SELECT o.occurrence_id, e.event_code, o.subject_label, o.occurred_dt,';
    PRINT '         i.obligation_name_snapshot, i.status, i.response_value,';
    PRINT '         i.completed_by, i.completed_dt, i.remarks';
    PRINT '  FROM GRAC_New.assurance_event_occurrence o';
    PRINT '  JOIN GRAC_New.event_type_master e ON e.event_type_id = o.event_type_id';
    PRINT '  LEFT JOIN GRAC_New.assurance_checklist_item i';
    PRINT '         ON i.occurrence_id = o.occurrence_id';
    PRINT '  ORDER BY o.occurred_dt DESC;';
    PRINT '';
    PRINT 'Then, non-production only:';
    PRINT '  DELETE FROM GRAC_New.assurance_checklist_evidence;';
    PRINT '  DELETE FROM GRAC_New.assurance_checklist_item;';
    PRINT '  DELETE FROM GRAC_New.assurance_event_occurrence;';
    PRINT '---------------------------------------------------------------';
    PRINT 'Nothing was dropped.';
    RETURN;
END
GO

IF OBJECT_ID('GRAC_New.assurance_checklist_evidence','U') IS NOT NULL
    DROP TABLE GRAC_New.assurance_checklist_evidence;
GO

IF OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NOT NULL
    DROP TABLE GRAC_New.assurance_checklist_item;
GO

IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NOT NULL
    DROP TABLE GRAC_New.assurance_event_occurrence;
GO

-- Menu + permissions.
DELETE rp
FROM GRAC_New.cm_role_permission rp
JOIN GRAC_New.cm_menu m ON m.menu_id = rp.menu_id
WHERE m.menu_code = N'assurance-occurrences';
GO

DELETE FROM GRAC_New.cm_menu WHERE menu_code = N'assurance-occurrences';
GO

-- Entity registrations.  Soft-retire rather than DELETE: change_management
-- rows raised elsewhere may still carry these entity_ids.
UPDATE GRAC_New.cm_entity_master
SET status = N'Inactive', updated_by = 'rollback-035', updated_dt = SYSUTCDATETIME()
WHERE entity_code IN (N'assurance-occurrences', N'assurance-checklist');
GO

PRINT '035 rollback complete. Runtime tables dropped, menu removed,';
PRINT '  entity registrations retired (not deleted).';
GO
