-- =====================================================================
-- 047 ROLLBACK -- remove the ACTIVATE action from cm_manage_repository
--
-- 047 ships one object: dbo.cm_manage_repository.  To roll it back, restore
-- the previous definition of that procedure.
--
-- OPTION A (preferred) -- restore from source control
--   Check out the revision of
--     database/002_control_management_procedures.sql
--   that precedes the ACTIVATE change and execute it.  002 is CREATE OR
--   ALTER throughout, so it simply overwrites the procedure.
--
-- OPTION B -- restore from the database itself
--   If a pre-047 definition was captured before deploying, replay it:
--     SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.cm_manage_repository'));
--   (Capture this BEFORE applying 047 if you want an in-database rollback
--   path.  SQL Server keeps no history of its own.)
--
-- THE CHECK CONSTRAINT
-- --------------------
-- 047 also widened ck_cm_chg_action to allow the 'Activate' action type.
-- Leaving it wide is harmless once the procedure can no longer emit that
-- value, and narrowing it will FAIL while any 'Activate' row still exists.
-- Only narrow it after clearing those rows (see below):
--
--   -- ALTER TABLE GRAC_New.change_management DROP CONSTRAINT ck_cm_chg_action;
--   -- ALTER TABLE GRAC_New.change_management
--   --   ADD CONSTRAINT ck_cm_chg_action
--   --       CHECK (action_type IN (N'Add', N'Edit', N'Inactive'));
--
-- 047 creates no tables, columns or seed rows.
--
-- ROWS ALREADY IN FLIGHT
-- ----------------------
-- Any change request left at 'Pending Approval' with action_type='Activate'
-- becomes un-appliable once the procedure no longer maps that action: the
-- checker apply falls back to 'SAVE' and will fail on the empty payload.
-- Clear them first.
--
--   SELECT change_request_id, entity_type, record_id, maker_user, entered_dt
--   FROM   GRAC_New.change_management
--   WHERE  action_type = N'Activate' AND status = N'Pending Approval';
--
-- Then either let checkers action them before rolling back, or cancel them.
-- Note this only clears the pending ones; narrowing the CHECK constraint also
-- requires deleting or rewriting any historical 'Activate' rows.
--
--   -- UPDATE GRAC_New.change_management
--   -- SET    status = N'Rejected',
--   --        checker_comments = N'Cancelled: Activate action rolled back.',
--   --        updated_dt = SYSUTCDATETIME()
--   -- WHERE  action_type = N'Activate' AND status = N'Pending Approval';
--
-- APPLICATION SIDE
-- ----------------
-- Also revert the Activate endpoint and the status-aware 3-dots menu, or the
-- UI will keep calling an action the procedure no longer understands:
--   src/ControlManagement.Web/Controllers/ControlManagementGatewayController.cs
--   src/ControlManagement.Api/Controllers/RepositoryController.cs
--   src/ControlManagement.Api/Validation/RepositoryCommandValidator.cs
--   src/ControlManagement.Web/wwwroot/js/repository.js
-- =====================================================================

SELECT change_request_id, entity_type, record_id, maker_user, entered_dt
FROM   GRAC_New.change_management
WHERE  action_type = N'Activate' AND status = N'Pending Approval';
GO

PRINT 'Review the rows above, then restore the pre-047 cm_manage_repository definition (see the notes at the top of this file).';
GO
