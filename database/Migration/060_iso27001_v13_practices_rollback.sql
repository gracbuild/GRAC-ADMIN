/* =====================================================================
   060_iso27001_v13_practices_rollback.sql

   Reverses 060_iso27001_v13_practices.sql -- removes the 1,218 Practices
   that load inserted, and their Statement mappings.

   RUN THE OBLIGATION ROLLBACKS FIRST
   ----------------------------------
   061-065 rollbacks must have been applied.  A Practice with Obligations
   still attached cannot be deleted (requirement_obligation.requirement_id
   is a foreign key), and this script refuses to start in that case rather
   than deleting half a catalogue.

   HOW THE ROWS ARE IDENTIFIED
   ---------------------------
   By the audit_trace_event rows 060 wrote -- one per inserted Practice,
   remarks stamped 'Bulk load: migration 060, ...'.  requirement itself has
   no remarks column, so the audit trail is the only record of which rows
   this load created.  A Practice somebody added by hand has no such event
   and is left alone.

   Rows are DELETED, not deactivated: a deactivated Practice keeps its
   requirement_name and its PR-### code, and would block a reload.

   audit_trace* is append-only by trigger and is NOT reversed.

   DRY RUN BY DEFAULT -- set @commit_rollback = 1 to actually delete.

   FILE ENCODING : UTF-8 with BOM.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @commit_rollback BIT = 0;   -- 0 = dry run (ROLLBACK).  1 = commit.
DECLARE @error NVARCHAR(4000);

IF @commit_rollback = 0
    PRINT N'060 rollback DRY RUN. Nothing will be deleted.';

BEGIN TRY
BEGIN TRANSACTION;

IF OBJECT_ID('tempdb..#doomed') IS NOT NULL DROP TABLE #doomed;

SELECT DISTINCT ae.entity_id AS requirement_id
INTO #doomed
FROM GRAC_New.audit_trace_event ae
WHERE ae.entity_type = N'requirements'
  AND ae.action_type = N'Add'
  AND ae.remarks LIKE N'Bulk load: migration 060, %';

DECLARE @n INT = (SELECT COUNT(*) FROM #doomed);
PRINT CONCAT(N'  Practices matched by the 060 load stamp: ', @n, N' (loaded: 1218).');

-- Refuse to proceed while Obligations still hang off them.
IF EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation ro JOIN #doomed d ON d.requirement_id = ro.requirement_id)
BEGIN
    SET @error = CONCAT(N'', (SELECT COUNT(*) FROM GRAC_New.requirement_obligation ro JOIN #doomed d ON d.requirement_id = ro.requirement_id),
                        N' Obligation(s) still reference these Practices. Run the 065, 064, 063, 062 and 061 rollbacks first.');
    THROW 50570, @error, 1;
END

IF EXISTS(SELECT 1 FROM GRAC_New.obligation_requirement_release_map m JOIN #doomed d ON d.requirement_id = m.requirement_id)
BEGIN
    SET @error = N'Obligation -> Practice mappings still reference these Practices. Run the 061-065 rollbacks first.';
    THROW 50571, @error, 1;
END

DELETE m FROM GRAC_New.framework_statement_requirement_map m JOIN #doomed d ON d.requirement_id = m.requirement_id;
PRINT CONCAT(N'  Deleted ', @@ROWCOUNT, N' Statement mappings.');

IF OBJECT_ID('GRAC_New.control_requirement_map','U') IS NOT NULL
    DELETE m FROM GRAC_New.control_requirement_map m JOIN #doomed d ON d.requirement_id = m.requirement_id;

DELETE r FROM GRAC_New.requirement r JOIN #doomed d ON d.requirement_id = r.requirement_id;
PRINT CONCAT(N'  Deleted ', @@ROWCOUNT, N' Practices.');

IF @commit_rollback = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'060 rollback COMMITTED.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'060 rollback DRY RUN COMPLETE -- ROLLED BACK, nothing deleted. Set @commit_rollback = 1 to apply.';
END

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

-- Verification: expect 0.
SELECT COUNT(*) AS remaining_060_practices
FROM GRAC_New.requirement r
WHERE EXISTS(SELECT 1 FROM GRAC_New.audit_trace_event ae
             WHERE ae.entity_type = N'requirements' AND ae.entity_id = r.requirement_id
               AND ae.remarks LIKE N'Bulk load: migration 060, %');
GO
