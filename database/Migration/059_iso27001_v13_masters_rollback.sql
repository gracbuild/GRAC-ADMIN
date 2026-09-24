/* =====================================================================
   059_iso27001_v13_masters_rollback.sql

   Reverses 059_iso27001_v13_masters.sql -- the ten Evidence Types and the
   'One-time' frequency option it seeded.

   RUN THE 060-065 ROLLBACKS FIRST.  These master rows are referenced by
   requirement_obligation_evidence.evidence_type_id (a foreign key) and by
   obligation_execution_spec / obligation_assurance_spec frequency ids.

   DEACTIVATE, NOT DELETE
   ----------------------
   Master rows are deactivated rather than deleted.  If anything still
   points at one, deleting it would fail on the foreign key; deactivating
   it keeps existing references intact while removing the option from every
   dropdown, which is what a rollback of a seed should do.  The script
   reports anything still referencing them so you can decide.

   To delete them outright once nothing references them, run the optional
   block at the end of this file.

   DRY RUN BY DEFAULT -- set @commit_rollback = 1 to apply.

   FILE ENCODING : UTF-8 with BOM.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @commit_rollback BIT = 0;   -- 0 = dry run (ROLLBACK).  1 = commit.
DECLARE @by NVARCHAR(100) = N'anoop.ps@soffit.in';

IF @commit_rollback = 0
    PRINT N'059 rollback DRY RUN. Nothing will be changed.';

-- What still references the seeded rows.
SELECT N'requirement_obligation_evidence' AS Referencing, COUNT(*) AS Rows_
FROM GRAC_New.requirement_obligation_evidence ev
JOIN GRAC_New.evidence_type_master e ON e.evidence_type_id = ev.evidence_type_id
WHERE e.evidence_type_code LIKE N'EVT-%'
UNION ALL
SELECT N'obligation_execution_spec (One-time)', COUNT(*)
FROM GRAC_New.obligation_execution_spec s
JOIN GRAC_New.reference_option o ON o.reference_option_id = s.execution_frequency_id
WHERE o.option_group = N'frequency-types' AND o.option_value = N'One-time'
UNION ALL
SELECT N'obligation_assurance_spec (One-time)', COUNT(*)
FROM GRAC_New.obligation_assurance_spec s
JOIN GRAC_New.reference_option o ON o.reference_option_id = s.assurance_frequency_id
WHERE o.option_group = N'frequency-types' AND o.option_value = N'One-time';

BEGIN TRY
BEGIN TRANSACTION;

UPDATE GRAC_New.evidence_type_master
   SET is_active = 0, updated_by = @by, updated_dt = SYSUTCDATETIME()
WHERE evidence_type_code IN (N'EVT-AGREEMENT', N'EVT-CHECKLIST', N'EVT-CONFIG-SCREENSHOT',
                             N'EVT-DOCUMENT', N'EVT-LOG', N'EVT-POLICY', N'EVT-PROCESS',
                             N'EVT-RECORD', N'EVT-REGISTER', N'EVT-REPORT');
PRINT CONCAT(N'  Deactivated ', @@ROWCOUNT, N' Evidence Types.');

UPDATE GRAC_New.reference_option
   SET status = N'Retired', updated_by = @by, updated_dt = SYSUTCDATETIME()
WHERE option_group = N'frequency-types' AND option_value = N'One-time';
PRINT CONCAT(N'  Retired ', @@ROWCOUNT, N' frequency option(s).');

IF @commit_rollback = 1
BEGIN
    COMMIT TRANSACTION;
    PRINT N'059 rollback COMMITTED.';
END
ELSE
BEGIN
    ROLLBACK TRANSACTION;
    PRINT N'059 rollback DRY RUN COMPLETE -- ROLLED BACK. Set @commit_rollback = 1 to apply.';
END

END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH
GO

/* OPTIONAL -- hard delete.  Only run this once the SELECT above reports 0
   referencing rows in every line, otherwise it fails on a foreign key.

DELETE FROM GRAC_New.evidence_type_master
WHERE evidence_type_code IN (N'EVT-AGREEMENT', N'EVT-CHECKLIST', N'EVT-CONFIG-SCREENSHOT',
                             N'EVT-DOCUMENT', N'EVT-LOG', N'EVT-POLICY', N'EVT-PROCESS',
                             N'EVT-RECORD', N'EVT-REGISTER', N'EVT-REPORT');

DELETE FROM GRAC_New.reference_option
WHERE option_group = N'frequency-types' AND option_value = N'One-time';
*/
