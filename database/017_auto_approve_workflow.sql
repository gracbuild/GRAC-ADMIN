/*
  GRAC Repository Management - Part 017
  Workflow auto-approval support.  Allow 'Auto Approved' in the change_management
  status CHECK constraint so existing deployments accept the new value emitted by
  cm_manage_repository when a maker submits a change and the workflow is
  configured for self approval.

  Safe to re-run.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF SCHEMA_ID('GRAC_New') IS NULL
    THROW 51501, 'Schema GRAC_New is missing. Run Repository Management schema scripts first.', 1;
GO

IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE name = 'ck_cm_chg_status'
      AND parent_object_id = OBJECT_ID('GRAC_New.change_management'))
BEGIN
    ALTER TABLE GRAC_New.change_management DROP CONSTRAINT ck_cm_chg_status;
END
GO

ALTER TABLE GRAC_New.change_management
    ADD CONSTRAINT ck_cm_chg_status
        CHECK (status IN (N'Pending Approval', N'Approved', N'Rejected', N'Sent Back', N'Auto Approved'));
GO

PRINT 'Migration 017 complete. change_management.ck_cm_chg_status now allows Auto Approved.';
GO
