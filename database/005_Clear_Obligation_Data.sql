/*
  Purpose:
    Safely remove already-added Control Management obligation data after the
    obligation model change.

  Scope:
    - Deletes child evidence records first.
    - Deletes obligation parent records second.
    - Keeps tables, constraints, procedures, and master data.
    - Resets identity values only after the delete succeeds.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
  BEGIN TRANSACTION;

  DECLARE @counts TABLE(stage NVARCHAR(20),table_name SYSNAME,row_count BIGINT);

  IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
    INSERT @counts SELECT 'Before','GRAC_New.requirement_obligation_evidence',COUNT(1) FROM GRAC_New.requirement_obligation_evidence;
  IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
    INSERT @counts SELECT 'Before','GRAC_New.requirement_obligation',COUNT(1) FROM GRAC_New.requirement_obligation;
  IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NOT NULL
    INSERT @counts SELECT 'Before','GRAC_New.obligation_evidence_type',COUNT(1) FROM GRAC_New.obligation_evidence_type;
  IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
    INSERT @counts SELECT 'Before','GRAC_New.obligation',COUNT(1) FROM GRAC_New.obligation;

  SELECT stage AS [Stage],table_name AS [TableName],row_count AS [RowCount] FROM @counts WHERE stage='Before' ORDER BY table_name;

  IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
    DELETE FROM GRAC_New.requirement_obligation_evidence;

  IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
    DELETE FROM GRAC_New.requirement_obligation;

  IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NOT NULL
    DELETE FROM GRAC_New.obligation_evidence_type;

  IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
    DELETE FROM GRAC_New.obligation;

  IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
    DBCC CHECKIDENT ('GRAC_New.requirement_obligation_evidence', RESEED, 0) WITH NO_INFOMSGS;

  IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
    DBCC CHECKIDENT ('GRAC_New.requirement_obligation', RESEED, 0) WITH NO_INFOMSGS;

  IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NOT NULL
    DBCC CHECKIDENT ('GRAC_New.obligation_evidence_type', RESEED, 0) WITH NO_INFOMSGS;

  IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
    DBCC CHECKIDENT ('GRAC_New.obligation', RESEED, 0) WITH NO_INFOMSGS;

  IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NOT NULL
    INSERT @counts SELECT 'After','GRAC_New.requirement_obligation_evidence',COUNT(1) FROM GRAC_New.requirement_obligation_evidence;
  IF OBJECT_ID('GRAC_New.requirement_obligation','U') IS NOT NULL
    INSERT @counts SELECT 'After','GRAC_New.requirement_obligation',COUNT(1) FROM GRAC_New.requirement_obligation;
  IF OBJECT_ID('GRAC_New.obligation_evidence_type','U') IS NOT NULL
    INSERT @counts SELECT 'After','GRAC_New.obligation_evidence_type',COUNT(1) FROM GRAC_New.obligation_evidence_type;
  IF OBJECT_ID('GRAC_New.obligation','U') IS NOT NULL
    INSERT @counts SELECT 'After','GRAC_New.obligation',COUNT(1) FROM GRAC_New.obligation;

  SELECT stage AS [Stage],table_name AS [TableName],row_count AS [RowCount] FROM @counts WHERE stage='After' ORDER BY table_name;

  COMMIT TRANSACTION;
END TRY
BEGIN CATCH
  IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH;
