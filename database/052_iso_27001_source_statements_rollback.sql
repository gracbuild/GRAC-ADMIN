/* =====================================================================
   052_iso_27001_source_statements_rollback.sql

   Reverses 052_iso_27001_source_statements.sql.

   Default behaviour is a soft rollback: the loaded statements are set
   to Retired, matching the platform convention that repository records
   are retired by status rather than physically deleted.

   Set @hard_delete = 1 for a true undo of the load. That path refuses
   to run if any loaded statement has since been mapped to a control,
   requirement or obligation, so it cannot silently break downstream
   records. Resolve those mappings first if a hard delete is required.

   AUDIT ROWS ARE NOT REMOVED, by either path. audit_trace,
   audit_trace_event and audit_trace_detail carry INSTEAD OF UPDATE,
   DELETE triggers that reject any attempt to change them, so the record
   that the load happened survives the rollback. That is the intended
   behaviour of an append-only trail, not an oversight.
   ===================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
BEGIN TRANSACTION;

DECLARE @by          NVARCHAR(100) = N'anoop.ps@soffit.in';
DECLARE @hard_delete BIT           = 0;
DECLARE @release_id  BIGINT;
DECLARE @error       NVARCHAR(2000);

IF OBJECT_ID('tempdb..#ref') IS NOT NULL DROP TABLE #ref;
CREATE TABLE #ref(statement_reference NVARCHAR(160) NOT NULL PRIMARY KEY);
INSERT #ref(statement_reference) VALUES
(N'5.1'),
(N'5.2'),
(N'5.3'),
(N'5.4'),
(N'5.5'),
(N'5.6'),
(N'5.7'),
(N'5.8'),
(N'5.9'),
(N'5.10'),
(N'5.11'),
(N'5.12'),
(N'5.13'),
(N'5.14'),
(N'5.15'),
(N'5.16'),
(N'5.17'),
(N'5.18'),
(N'5.19'),
(N'5.20'),
(N'5.21'),
(N'5.22'),
(N'5.23'),
(N'5.24'),
(N'5.25'),
(N'5.26'),
(N'5.27'),
(N'5.28'),
(N'5.29'),
(N'5.30'),
(N'5.31'),
(N'5.32'),
(N'5.33'),
(N'5.34'),
(N'5.35'),
(N'5.36'),
(N'5.37'),
(N'6.1'),
(N'6.2'),
(N'6.3'),
(N'6.4'),
(N'6.5'),
(N'6.6'),
(N'6.7'),
(N'6.8'),
(N'7.1'),
(N'7.2'),
(N'7.3'),
(N'7.4'),
(N'7.5'),
(N'7.6'),
(N'7.7'),
(N'7.8'),
(N'7.9'),
(N'7.10'),
(N'7.11'),
(N'7.12'),
(N'7.13'),
(N'7.14'),
(N'8.1'),
(N'8.2'),
(N'8.3'),
(N'8.4'),
(N'8.5'),
(N'8.6'),
(N'8.7'),
(N'8.8'),
(N'8.9'),
(N'8.10'),
(N'8.11'),
(N'8.12'),
(N'8.13'),
(N'8.14'),
(N'8.15'),
(N'8.16'),
(N'8.17'),
(N'8.18'),
(N'8.19'),
(N'8.20'),
(N'8.21'),
(N'8.22'),
(N'8.23'),
(N'8.24'),
(N'8.25'),
(N'8.26'),
(N'8.27'),
(N'8.28'),
(N'8.29'),
(N'8.30'),
(N'8.31'),
(N'8.32'),
(N'8.33'),
(N'8.34');

-- Scope the rollback to the release the load targeted.
SELECT TOP 1 @release_id = fs.release_id
FROM GRAC_New.framework_statement fs
JOIN #ref r ON r.statement_reference = fs.statement_reference
ORDER BY fs.framework_statement_id;

IF @release_id IS NULL
BEGIN
  PRINT N'Nothing to roll back: none of the loaded statement references are present.';
  COMMIT TRANSACTION;
  RETURN;
END

IF OBJECT_ID('tempdb..#target') IS NOT NULL DROP TABLE #target;
SELECT fs.framework_statement_id INTO #target
FROM GRAC_New.framework_statement fs
JOIN #ref r ON r.statement_reference = fs.statement_reference
WHERE fs.release_id = @release_id;

IF @hard_delete = 1
BEGIN
  IF EXISTS(SELECT 1 FROM GRAC_New.framework_statement_control_map m JOIN #target t ON t.framework_statement_id = m.framework_statement_id)
   OR EXISTS(SELECT 1 FROM GRAC_New.framework_statement_requirement_map m JOIN #target t ON t.framework_statement_id = m.framework_statement_id)
   OR EXISTS(SELECT 1 FROM GRAC_New.obligation o JOIN #target t ON t.framework_statement_id = o.framework_statement_id)
  BEGIN
    SET @error = N'Hard delete refused: loaded statements are mapped to controls, requirements or obligations. Remove those mappings first, or use the soft rollback.';
    THROW 50203, @error, 1;
  END

  -- Audit rows are deliberately left alone; the audit tables are
  -- append-only and protected by INSTEAD OF UPDATE, DELETE triggers.
  DELETE fs FROM GRAC_New.framework_statement fs
  JOIN #target t ON t.framework_statement_id = fs.framework_statement_id;

  PRINT CONCAT(N'052 rollback: hard-deleted ', @@ROWCOUNT, N' statement(s).');
END
ELSE
BEGIN
  UPDATE fs
    SET fs.status = N'Retired', fs.updated_by = @by, fs.updated_dt = SYSUTCDATETIME()
  FROM GRAC_New.framework_statement fs
  JOIN #target t ON t.framework_statement_id = fs.framework_statement_id
  WHERE fs.status <> N'Retired';

  PRINT CONCAT(N'052 rollback: retired ', @@ROWCOUNT, N' statement(s).');
END

-- The default classification is left in place: it is harmless, and other
-- statements may already reference it. Remove manually if required.

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
  IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH
GO
