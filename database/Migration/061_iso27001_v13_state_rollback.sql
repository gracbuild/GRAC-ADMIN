/* =====================================================================
   061_iso27001_v13_state_rollback.sql

   Reverses 061_iso27001_v13_state.sql -- removes the 3075 State
   Obligations that load wrote, and everything hanging off them.

   HOW THE ROWS ARE IDENTIFIED
   ---------------------------
   By requirement_obligation.remarks, which 061 stamps with

       'Bulk load 061. ... sheet State ...'

   on every row it inserts.  Nothing else in the database writes that
   prefix, and 055 COALESCEs remarks on update so an interactive Save
   cannot blank it.  An Obligation somebody created by hand is therefore
   never touched, even if it shares a name with a loaded one.

   Rows are DELETED, not deactivated.  A deactivated Obligation would still
   occupy its (Practice, Obligation Name) pair and block a reload.

   WHAT IS NOT REVERSED
   --------------------
   audit_trace / audit_trace_event / audit_trace_detail.  Those tables are
   append-only by trigger and the load's history stays readable by design.

   DRY RUN BY DEFAULT -- set @commit_rollback = 1 to actually delete.

   FILE ENCODING : UTF-8 with BOM.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @commit_rollback BIT = 0;   -- 0 = dry run (ROLLBACK).  1 = commit.

IF @commit_rollback = 0
    PRINT N'061 rollback DRY RUN. Nothing will be deleted.';

BEGIN TRY
BEGIN TRANSACTION;

IF OBJECT_ID('tempdb..#doomed') IS NOT NULL DROP TABLE #doomed;

SELECT ro.obligation_id
INTO #doomed
FROM GRAC_New.requirement_obligation ro
WHERE ro.remarks LIKE N'Bulk load 061. %';

DECLARE @n INT = (SELECT COUNT(*) FROM #doomed);
PRINT CONCAT(N'  State Obligations matched by the 061 load stamp: ', @n, N' (loaded: 3075).');

DELETE l FROM GRAC_New.obligation_state_evidence_link l JOIN #doomed d ON d.obligation_id = l.obligation_id;
DELETE e FROM GRAC_New.requirement_obligation_evidence e JOIN #doomed d ON d.obligation_id = e.obligation_id;
DELETE x FROM GRAC_New.obligation_state_rule x JOIN #doomed d ON d.obligation_id = x.obligation_id;

IF OBJECT_ID('GRAC_New.obligation_framework_statement_map','U') IS NOT NULL
    DELETE m FROM GRAC_New.obligation_framework_statement_map m JOIN #doomed d ON d.obligation_id = m.obligation_id;

DELETE m FROM GRAC_New.obligation_requirement_release_map m JOIN #doomed d ON d.obligation_id = m.obligation_id;

-- Runtime assurance rows would otherwise hold a foreign key on the parent.
IF OBJECT_ID('GRAC_New.assurance_checklist_item','U') IS NOT NULL
BEGIN
    IF OBJECT_ID('GRAC_New.assurance_checklist_evidence','U') IS NOT NULL
        DELETE ce FROM GRAC_New.assurance_checklist_evidence ce
        JOIN GRAC_New.assurance_checklist_item ci ON ci.checklist_item_id = ce.checklist_item_id
        JOIN #doomed d ON d.obligation_id = ci.obligation_id;

    DELETE ci FROM GRAC_New.assurance_checklist_item ci JOIN #doomed d ON d.obligation_id = ci.obligation_id;
END

DELETE ro FROM GRAC_New.requirement_obligation ro JOIN #doomed d ON d.obligation_id = ro.obligation_id;

PRINT CONCAT(N'  Deleted ', @@ROWCOUNT, N' State Obligation parent rows.');

IF @commit_rollback = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'061 rollback COMMITTED.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'061 rollback DRY RUN COMPLETE -- ROLLED BACK, nothing deleted. Set @commit_rollback = 1 to apply.';
END

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- Verification: expect 0.
SELECT COUNT(*) AS remaining_state_obligations
FROM GRAC_New.requirement_obligation
WHERE remarks LIKE N'Bulk load 061. %';
GO
