-- =====================================================================
-- 034 ROLLBACK -- restore the assurance procs to their 028 / 030 shape
--
-- Reverses database/034_assurance_trigger_procs.sql:
--
--   * sp_cm_obligation_assurance_get   -> 028 projection (no trigger cols)
--   * sp_cm_obligation_assurance_save  -> 028 signature (no trigger params)
--   * cm_manage_obligation_taxonomy    -> 030 shape (assurance branch does
--                                          not forward the new payload keys)
--
-- This does NOT drop the underlying columns -- that is 033's rollback.
-- Run this one FIRST, then 033's, so the procs never reference columns that
-- have already been dropped.
--
-- Data written while 034 was live is preserved: trigger_mode and
-- event_type_id keep their values, they simply stop being read or written.
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- =====================================================================
-- 1. GET -- 028 projection.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_assurance_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        s.assurance_spec_id       AS Id,
        s.obligation_id           AS ObligationId,
        s.verification_method     AS VerificationMethod,
        s.scope                   AS Scope,
        s.assurance_frequency_id  AS AssuranceFrequencyId,
        freq.option_label         AS AssuranceFrequency,
        s.assurance_party         AS AssuranceParty,
        s.remarks                 AS Remarks,
        s.status                  AS Status,
        s.entered_by              AS EnteredBy,
        s.entered_dt              AS EnteredDt,
        s.updated_by              AS UpdatedBy,
        s.updated_dt              AS UpdatedDt
    FROM GRAC_New.obligation_assurance_spec s
    LEFT JOIN GRAC_New.reference_option freq
        ON freq.reference_option_id = s.assurance_frequency_id
    WHERE s.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR s.status = N'Active')
    ORDER BY s.entered_dt DESC, s.assurance_spec_id DESC;
END
GO

-- =====================================================================
-- 2. SAVE -- 028 signature.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_assurance_save
    @p_id                     BIGINT       = 0,
    @p_obligation_id          BIGINT,
    @p_verification_method    NVARCHAR(500),
    @p_scope                  NVARCHAR(500) = NULL,
    @p_assurance_frequency_id BIGINT        = NULL,
    @p_assurance_party        NVARCHAR(250) = NULL,
    @p_remarks                NVARCHAR(MAX) = NULL,
    @p_status                 NVARCHAR(30)  = N'Active',
    @p_usr_id                 NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52830, 'sp_cm_obligation_assurance_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_verification_method)), N'') IS NULL
        THROW 52831, 'sp_cm_obligation_assurance_save: @p_verification_method required.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'Assurance')
        THROW 52832, 'sp_cm_obligation_assurance_save: obligation is not typed as Assurance.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, scope, assurance_frequency_id,
            assurance_party, remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_verification_method, @p_scope, @p_assurance_frequency_id,
               @p_assurance_party, @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_assurance_spec
        SET verification_method     = @p_verification_method,
            scope                   = @p_scope,
            assurance_frequency_id  = @p_assurance_frequency_id,
            assurance_party         = @p_assurance_party,
            remarks                 = @p_remarks,
            status                  = @p_status,
            updated_by              = @p_usr_id,
            updated_dt              = SYSUTCDATETIME()
        WHERE assurance_spec_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

PRINT '034 rollback: assurance get/save restored to the 028 shape.';
PRINT 'IMPORTANT: also re-run 030_obligation_taxonomy_dispatcher_action_override.sql';
PRINT 'to restore cm_manage_obligation_taxonomy, then 033s rollback to drop the columns.';
GO
