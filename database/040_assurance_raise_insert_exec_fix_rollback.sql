-- =====================================================================
-- 040 ROLLBACK -- restore the 038 shape of sp_cm_assurance_occurrence_raise
--
-- Puts ROLLBACK back in place of COMMIT on the duplicate-raise guard.
--
-- Doing so REINTRODUCES the defect found by 039 check G1: the procedure can
-- no longer be called via INSERT ... EXEC, and callers that capture the
-- returned OccurrenceId will see
--
--     Msg 3916 -- Cannot use the ROLLBACK statement within an
--     INSERT-EXEC statement.
--
-- instead of the intended 52905.  There is no functional reason to prefer
-- the old form -- nothing is written before the guard, so ROLLBACK and
-- COMMIT are equivalent there.  This script exists only for completeness of
-- the migration pair.
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_occurrence_raise
    @p_event_type_id     BIGINT,
    @p_subject_entity    NVARCHAR(100),
    @p_subject_record_id BIGINT,
    @p_subject_label     NVARCHAR(300) = NULL,
    @p_occurred_dt       DATETIME2(3)  = NULL,
    @p_raise_source      NVARCHAR(20)  = N'Manual',
    @p_remarks           NVARCHAR(MAX) = NULL,
    @p_usr_id            NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_event_type_id IS NULL OR @p_event_type_id <= 0
        THROW 52900, 'sp_cm_assurance_occurrence_raise: event type is required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_subject_entity)), N'') IS NULL
        THROW 52901, 'sp_cm_assurance_occurrence_raise: subject entity is required.', 1;
    IF @p_subject_record_id IS NULL OR @p_subject_record_id <= 0
        THROW 52902, 'sp_cm_assurance_occurrence_raise: subject record is required.', 1;

    DECLARE @expected_subject NVARCHAR(100), @event_name NVARCHAR(120);
    SELECT @expected_subject = e.subject_entity, @event_name = e.event_name
    FROM GRAC_New.event_type_master e
    JOIN GRAC_New.event_type_master p ON p.event_type_id = e.parent_event_type_id
    WHERE e.event_type_id = @p_event_type_id
      AND e.status = N'Active' AND p.status = N'Active';

    IF @event_name IS NULL
        THROW 52903, 'sp_cm_assurance_occurrence_raise: event must be an active event under an active domain.', 1;

    IF @expected_subject IS NOT NULL AND @expected_subject <> @p_subject_entity
        THROW 52904, 'sp_cm_assurance_occurrence_raise: subject does not belong to the register this event applies to.', 1;

    SET @p_occurred_dt = COALESCE(@p_occurred_dt, SYSUTCDATETIME());
    SET @p_subject_label = NULLIF(LTRIM(RTRIM(@p_subject_label)), N'');

    IF @p_subject_label IS NULL AND @p_subject_entity = N'cm_user'
        SELECT @p_subject_label = CONCAT(u.user_name, N' (', u.login_id, N')')
        FROM GRAC_New.cm_user u WHERE u.user_id = @p_subject_record_id;

    IF @p_subject_label IS NULL
        SET @p_subject_label = CONCAT(@p_subject_entity, N' #', @p_subject_record_id);

    SET @p_subject_label = LEFT(@p_subject_label, 300);

    BEGIN TRAN;

    IF EXISTS (SELECT 1 FROM GRAC_New.assurance_event_occurrence WITH (UPDLOCK, HOLDLOCK)
               WHERE event_type_id = @p_event_type_id
                 AND subject_entity = @p_subject_entity
                 AND subject_record_id = @p_subject_record_id
                 AND status = N'Open')
    BEGIN
        ROLLBACK;
        THROW 52905, 'sp_cm_assurance_occurrence_raise: an open checklist already exists for this event and subject.', 1;
    END

    INSERT GRAC_New.assurance_event_occurrence(
        event_type_id, subject_entity, subject_record_id, subject_label,
        occurred_dt, raise_source, remarks, status, entered_by)
    VALUES(@p_event_type_id, @p_subject_entity, @p_subject_record_id, @p_subject_label,
           @p_occurred_dt, @p_raise_source, @p_remarks, N'Open', @p_usr_id);

    DECLARE @occurrence_id BIGINT = SCOPE_IDENTITY();

    INSERT GRAC_New.assurance_checklist_item(
        occurrence_id, obligation_id, assurance_spec_id,
        obligation_name_snapshot, verification_method_snapshot,
        assurance_party_snapshot, scope_snapshot, due_dt,
        status, entered_by)
    SELECT @occurrence_id, m.obligation_id, m.assurance_spec_id,
           m.obligation_name, m.verification_method,
           m.assurance_party, m.scope,
           CASE WHEN m.sla_days IS NULL THEN NULL
                ELSE DATEADD(DAY, m.sla_days, @p_occurred_dt) END,
           N'Pending', @p_usr_id
    FROM GRAC_New.fn_cm_assurance_specs_for_event(@p_event_type_id) m;

    DECLARE @item_count INT = @@ROWCOUNT;

    COMMIT;

    SELECT @occurrence_id AS Id,
           @occurrence_id AS OccurrenceId,
           @item_count    AS ChecklistItemCount,
           @event_name    AS EventName,
           @p_subject_label AS SubjectLabel;
END
GO

PRINT '040 rollback complete. The INSERT ... EXEC defect is reinstated.';
GO
