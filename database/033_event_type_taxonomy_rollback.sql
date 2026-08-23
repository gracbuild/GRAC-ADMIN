-- =====================================================================
-- 033 ROLLBACK -- Event-driven Assurance, Phase A
--
-- Reverses database/033_event_type_taxonomy.sql.
--
-- Order:
--   1. Restore cm_get_obligation_taxonomy to its 029 shape (drops the
--      'event-types' branch).
--   2. Drop sp_cm_event_type_list.
--   3. Drop the CHECK constraint and the two spec columns.
--   4. Drop event_type_master.
--   5. Retire the assurance-trigger-modes reference options.
--
-- SAFETY GATE
-- -----------
-- If any obligation_assurance_spec row has been classified (trigger_mode
-- or event_type_id set), dropping those columns destroys authored compliance
-- configuration.  This script refuses and tells the operator what to clear.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- =====================================================================
-- 0. Safety gate.
-- =====================================================================
DECLARE @classified INT = 0;

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','trigger_mode') IS NOT NULL
    SET @classified = (
        SELECT COUNT(1) FROM GRAC_New.obligation_assurance_spec
        WHERE trigger_mode IS NOT NULL OR event_type_id IS NOT NULL);

IF @classified > 0
BEGIN
    PRINT '---------------------------------------------------------------';
    PRINT 'ROLLBACK HALTED: assurance specs have been classified.';
    PRINT '';
    PRINT 'Classified spec count:';
    PRINT CONVERT(NVARCHAR(20), @classified);
    PRINT '';
    PRINT 'Dropping trigger_mode / event_type_id would destroy authored';
    PRINT 'compliance configuration.  Inspect first:';
    PRINT '';
    PRINT '  SELECT s.assurance_spec_id, s.obligation_id,';
    PRINT '         s.trigger_mode, e.event_code AS EventCode';
    PRINT '  FROM GRAC_New.obligation_assurance_spec s';
    PRINT '  LEFT JOIN GRAC_New.event_type_master e';
    PRINT '         ON e.event_type_id = s.event_type_id';
    PRINT '  WHERE s.trigger_mode IS NOT NULL OR s.event_type_id IS NOT NULL;';
    PRINT '';
    PRINT 'Then clear them (non-production only) and re-run:';
    PRINT '  UPDATE GRAC_New.obligation_assurance_spec';
    PRINT '  SET trigger_mode = NULL, event_type_id = NULL;';
    PRINT '---------------------------------------------------------------';
    PRINT 'Nothing was dropped.';
    RETURN;
END
GO

-- =====================================================================
-- 1. Restore cm_get_obligation_taxonomy to the 029 shape.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_get_obligation_taxonomy
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30)  = N'QUERY',
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N'',
    @p_page        INT           = 1,
    @p_page_size   INT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @p_entity_type = N'obligation-types'
    BEGIN
        EXEC dbo.sp_cm_obligation_type_master_list;
        RETURN;
    END

    DECLARE @obligation_id BIGINT =
        COALESCE(TRY_CAST(JSON_VALUE(@p_payload, '$.obligationId') AS BIGINT), @p_id);

    IF @obligation_id IS NULL OR @obligation_id <= 0
    BEGIN
        RAISERROR('cm_get_obligation_taxonomy: obligationId is required for entity_type %s.', 16, 1, @p_entity_type);
        RETURN;
    END

    IF @p_entity_type = N'obligation-state'
        EXEC dbo.sp_cm_obligation_state_get           @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-execution'
        EXEC dbo.sp_cm_obligation_execution_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-assurance'
        EXEC dbo.sp_cm_obligation_assurance_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-event-response'
        EXEC dbo.sp_cm_obligation_event_response_get  @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-constraint'
        EXEC dbo.sp_cm_obligation_constraint_get      @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-retention'
        EXEC dbo.sp_cm_obligation_retention_get       @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE IF @p_entity_type = N'obligation-evidence-links'
        EXEC dbo.sp_cm_obligation_evidence_links_get  @p_obligation_id = @obligation_id, @p_include_inactive = 0;
    ELSE
        RAISERROR('cm_get_obligation_taxonomy: unknown entity_type %s.', 16, 1, @p_entity_type);
END
GO

-- =====================================================================
-- 2. Drop the list proc.
-- =====================================================================
IF OBJECT_ID('dbo.sp_cm_event_type_list','P') IS NOT NULL
    DROP PROCEDURE dbo.sp_cm_event_type_list;
GO

-- =====================================================================
-- 3. Drop the CHECK constraint, then the spec columns (FKs go with them).
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_cm_assurance_spec_trigger')
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP CONSTRAINT ck_cm_assurance_spec_trigger;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_cm_assurance_spec_event_type')
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP CONSTRAINT fk_cm_assurance_spec_event_type;
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','event_type_id') IS NOT NULL
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP COLUMN event_type_id;
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','trigger_mode') IS NOT NULL
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP COLUMN trigger_mode;
GO

-- =====================================================================
-- 4. Drop the taxonomy table.
-- =====================================================================
IF OBJECT_ID('GRAC_New.event_type_master','U') IS NOT NULL
    DROP TABLE GRAC_New.event_type_master;
GO

-- =====================================================================
-- 5. Retire the trigger-mode options.  Soft-retire rather than DELETE --
--    reference_option rows may be pointed at by history elsewhere.
-- =====================================================================
UPDATE GRAC_New.reference_option
SET status = N'Inactive', updated_by = 'rollback-033', updated_dt = SYSUTCDATETIME()
WHERE option_group = N'assurance-trigger-modes';
GO

PRINT '033 rollback complete.';
PRINT '  event_type_master dropped, spec columns removed,';
PRINT '  cm_get_obligation_taxonomy restored to its 029 shape,';
PRINT '  assurance-trigger-modes options retired (not deleted).';
GO
