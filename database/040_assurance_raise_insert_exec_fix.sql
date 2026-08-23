-- =====================================================================
-- 040 -- Fix: sp_cm_assurance_occurrence_raise cannot be called via
--        INSERT ... EXEC
--
-- FOUND BY the 039 smoke test, check G1:
--
--     Msg 3916 -- Cannot use the ROLLBACK statement within an
--     INSERT-EXEC statement.
--
-- The duplicate-raise guard was written as:
--
--     BEGIN TRAN;
--     IF EXISTS (... an Open occurrence ...)
--     BEGIN
--         ROLLBACK;
--         THROW 52905, '...already exists...', 1;
--     END
--
-- SQL Server forbids ROLLBACK inside a procedure invoked by INSERT ... EXEC.
-- So any caller that captures the returned OccurrenceId -- the natural way to
-- call this procedure -- gets an opaque 3916 instead of the intended 52905.
--
-- WHY COMMIT AND NOT ROLLBACK
-- ---------------------------
-- At that point NOTHING HAS BEEN WRITTEN: the only statement executed inside
-- the transaction is the EXISTS check.  COMMIT and ROLLBACK are therefore
-- identical in effect -- both simply release the locks -- but COMMIT is legal
-- under INSERT ... EXEC.
--
-- The UPDLOCK / HOLDLOCK on the EXISTS check is retained.  That is what stops
-- two concurrent raises from both passing the guard, and it must stay inside
-- the transaction to hold until the decision is made.
--
-- THE SAME PATTERN ELSEWHERE
-- --------------------------
-- Five other places use ROLLBACK-then-THROW.  Analysed, not blindly changed:
--
--   SAFE AS-IS -- nothing written before the guard, so they would also work
--   if switched, but they are only ever called with a plain EXEC from
--   cm_manage_repository and re-emitting them risks introducing new faults
--   for a hypothetical caller:
--     031  sp_cm_change_bundle_approve    (no pending / self-approval guards)
--     031  sp_cm_change_bundle_reject     (no pending guard)
--     031  sp_cm_change_bundle_send_back  (no pending guard)
--
--   MUST KEEP ROLLBACK -- a write has already happened, so rolling back is
--   the correct behaviour and this procedure genuinely cannot be used with
--   INSERT ... EXEC:
--     032  cm_manage_obligation_composite (master save failed, 50085)
--
-- If any of those four ever needs to be called via INSERT ... EXEC, the first
-- three can take the same COMMIT change; the fourth needs its result captured
-- some other way (OUTPUT parameter, or a follow-up SELECT).
--
-- Preflight: 038.
--
-- Rollback: database/040_assurance_raise_insert_exec_fix_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','sla_days') IS NULL
BEGIN
    RAISERROR('040 preflight failed: run 038 (SLA) first.', 16, 1);
    SET NOEXEC ON;
END
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

    -- The column is 300 wide and user_name + login_id can exceed it.
    SET @p_subject_label = LEFT(@p_subject_label, 300);

    BEGIN TRAN;

    -- Guard.  UPDLOCK / HOLDLOCK holds until the decision is made, so two
    -- concurrent raises cannot both pass.
    IF EXISTS (SELECT 1 FROM GRAC_New.assurance_event_occurrence WITH (UPDLOCK, HOLDLOCK)
               WHERE event_type_id = @p_event_type_id
                 AND subject_entity = @p_subject_entity
                 AND subject_record_id = @p_subject_record_id
                 AND status = N'Open')
    BEGIN
        -- COMMIT, not ROLLBACK.  Nothing has been written -- the only
        -- statement in this transaction is the EXISTS above -- so the two are
        -- equivalent here, but ROLLBACK is illegal when this procedure is
        -- invoked by INSERT ... EXEC (Msg 3916).  See the header.
        COMMIT;
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

PRINT '040 complete. sp_cm_assurance_occurrence_raise is now safe to call';
PRINT '  via INSERT ... EXEC; the duplicate guard returns 52905 as intended.';
PRINT '  Re-run 039 -- check G1 should now PASS.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
