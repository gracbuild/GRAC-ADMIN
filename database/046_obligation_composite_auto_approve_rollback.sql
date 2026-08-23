-- =====================================================================
-- 046 ROLLBACK -- revert Obligation Master auto self-approval.
--
-- 046 only ALTERs two existing procedures; it creates no new objects and
-- no schema, so there is nothing to DROP.  Reverting means restoring the
-- previous definitions, which live in their own migrations:
--
--     database/031_change_management_bundle.sql
--         -> sp_cm_change_bundle_approve without the optional
--            @p_status_override / @p_action_label / @p_suppress_result /
--            @p_applied_record_id parameters.
--
--     database/032_obligation_composite_dispatcher.sql
--         -> cm_manage_obligation_composite without the PATH B2
--            auto-approval branch (always returns 'Pending Approval').
--
-- Both are CREATE OR ALTER and safe to re-run, so:
--
--     sqlcmd -S <server> -d <db> -i database/031_change_management_bundle.sql
--     sqlcmd -S <server> -d <db> -i database/032_obligation_composite_dispatcher.sql
--
-- Data note: obligations that were already auto-approved stay applied and
-- keep their 'Auto Approved' change_management rows.  That status is part
-- of ck_cm_chg_status (017) and is read by the change history screens, so
-- rolling the code back leaves the audit trail valid and needs no data fix.
-- =====================================================================
SET NOCOUNT ON;
GO

RAISERROR('046 rollback: re-run 031_change_management_bundle.sql and 032_obligation_composite_dispatcher.sql to restore the pre-046 procedure definitions. No objects were dropped.', 10, 1) WITH NOWAIT;
GO
