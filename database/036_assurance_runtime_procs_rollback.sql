-- =====================================================================
-- 036 ROLLBACK -- Event-driven Assurance, Phase B runtime procedures
--
-- Reverses database/036_assurance_runtime_procs.sql by dropping the eight
-- procedures it installed.  The runtime TABLES are untouched -- that is
-- 035's rollback.
--
-- Run this BEFORE 035's rollback so no procedure is left referencing a
-- table that has already been dropped.
--
-- Dropping these procedures makes the Event Checklists screens inoperable
-- but destroys no data: occurrences and completed checklist items remain
-- readable by direct query.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('dbo.cm_manage_assurance_runtime','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_manage_assurance_runtime;
GO

IF OBJECT_ID('dbo.cm_get_assurance_runtime','P') IS NOT NULL
    DROP PROCEDURE dbo.cm_get_assurance_runtime;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_event_subjects','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_event_subjects;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_occurrence_cancel','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_occurrence_cancel;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_checklist_reopen','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_checklist_reopen;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_checklist_complete','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_checklist_complete;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_checklist_list','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_checklist_list;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_occurrence_list','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_occurrence_list;
GO

IF OBJECT_ID('dbo.sp_cm_assurance_occurrence_raise','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_assurance_occurrence_raise;
GO

PRINT '036 rollback complete. Runtime procedures dropped; tables and data untouched.';
PRINT 'Run 035s rollback next if the tables are also being removed.';
GO
