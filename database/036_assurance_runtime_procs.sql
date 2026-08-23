-- =====================================================================
-- 036 -- Event-driven Assurance, Phase B: runtime procedures
--
-- Installs the read/write path for the runtime tables from 035, plus a
-- dispatcher pair matching the pattern already used by assurance and the
-- obligation taxonomy:
--
--     dbo.cm_get_assurance_runtime      -- entity types below, QUERY
--     dbo.cm_manage_assurance_runtime   -- entity types below, RAISE /
--                                          COMPLETE / REOPEN / CANCEL
--
-- Entity types:
--     assurance-occurrences   list / get one (with its checklist as JSON)
--     assurance-checklist     items for one occurrence
--     event-subjects          selectable subjects for a chosen event type
--
-- Actions on cm_manage_assurance_runtime:
--     RAISE     create an occurrence and generate its checklist
--     COMPLETE  record Pass / Fail / Not Applicable on one item
--     REOPEN    return a completed item to Pending
--     CANCEL    cancel an entire occurrence
--
-- NO MAKER-CHECKER.  These procedures write directly.  See the governance
-- note in 035 -- routing completion through change_management would put one
-- approval row in the queue per assurance per employee.
--
-- Preflight: 035.
--
-- Rollback: database/036_assurance_runtime_procs_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.assurance_event_occurrence','U') IS NULL
BEGIN
    RAISERROR('036 preflight failed: run 035 (runtime schema) first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_cm_assurance_occurrence_raise
--
--    Records that an event happened and generates the checklist in one
--    transaction: an occurrence with no items would be a lie, and items
--    with no occurrence are orphans.
--
--    Matching rule -- every Active Assurance obligation whose spec is
--    EventDriven and points at this exact leaf event.
--
--    Applicability (role / department / location filtering) is NOT applied
--    here.  Phase D adds it; the seam is the applicability_rule table that
--    already exists.  Until then every matching rule is generated, which is
--    the safe direction to be wrong in -- an extra check gets marked Not
--    Applicable, a missing check goes unnoticed.
-- =====================================================================
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

    -- Must be an active leaf under an active domain.  A domain root is a
    -- grouping, not a raisable event.
    DECLARE @expected_subject NVARCHAR(100), @event_name NVARCHAR(120);
    SELECT @expected_subject = e.subject_entity, @event_name = e.event_name
    FROM GRAC_New.event_type_master e
    JOIN GRAC_New.event_type_master p ON p.event_type_id = e.parent_event_type_id
    WHERE e.event_type_id = @p_event_type_id
      AND e.status = N'Active' AND p.status = N'Active';

    IF @event_name IS NULL
        THROW 52903, 'sp_cm_assurance_occurrence_raise: event must be an active event under an active domain.', 1;

    -- The subject must belong to the register this event type declares.
    IF @expected_subject IS NOT NULL AND @expected_subject <> @p_subject_entity
        THROW 52904, 'sp_cm_assurance_occurrence_raise: subject does not belong to the register this event applies to.', 1;

    SET @p_occurred_dt = COALESCE(@p_occurred_dt, SYSUTCDATETIME());
    SET @p_subject_label = NULLIF(LTRIM(RTRIM(@p_subject_label)), N'');

    -- Resolve a display label when the caller did not supply one.  Denormalized
    -- deliberately (see 035) so the checklist survives the subject changing.
    IF @p_subject_label IS NULL AND @p_subject_entity = N'cm_user'
        SELECT @p_subject_label = CONCAT(u.user_name, N' (', u.login_id, N')')
        FROM GRAC_New.cm_user u WHERE u.user_id = @p_subject_record_id;

    IF @p_subject_label IS NULL
        SET @p_subject_label = CONCAT(@p_subject_entity, N' #', @p_subject_record_id);

    BEGIN TRAN;

    -- Idempotency.  ux_cm_assurance_occurrence_open enforces this at the
    -- storage layer; checking first turns a raw 2601 into a usable message.
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

    -- Generate the checklist, snapshotting the wording as it stands now.
    INSERT GRAC_New.assurance_checklist_item(
        occurrence_id, obligation_id, assurance_spec_id,
        obligation_name_snapshot, verification_method_snapshot,
        assurance_party_snapshot, scope_snapshot,
        status, entered_by)
    SELECT
        @occurrence_id,
        ro.obligation_id,
        s.assurance_spec_id,
        COALESCE(ro.obligation_name, LEFT(ro.obligation_text, 500), CONCAT(N'Obligation #', ro.obligation_id)),
        s.verification_method,
        s.assurance_party,
        s.scope,
        N'Pending',
        @p_usr_id
    FROM GRAC_New.obligation_assurance_spec s
    JOIN GRAC_New.requirement_obligation ro ON ro.obligation_id = s.obligation_id
    WHERE s.status = N'Active'
      AND ro.status = N'Active'
      AND s.trigger_mode = N'EventDriven'
      AND s.event_type_id = @p_event_type_id;

    DECLARE @item_count INT = @@ROWCOUNT;

    COMMIT;

    SELECT @occurrence_id AS Id,
           @occurrence_id AS OccurrenceId,
           @item_count    AS ChecklistItemCount,
           @event_name    AS EventName,
           @p_subject_label AS SubjectLabel;
END
GO

-- =====================================================================
-- 2. sp_cm_assurance_occurrence_list
--    Occurrence grid with completion progress, so the list answers "what
--    still needs doing" without a second round-trip per row.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_occurrence_list
    @p_id     BIGINT        = 0,
    @p_search NVARCHAR(250) = N'',
    @p_status NVARCHAR(30)  = N''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        o.occurrence_id      AS Id,
        o.occurrence_id      AS OccurrenceId,
        o.event_type_id      AS EventTypeId,
        e.event_code         AS EventCode,
        e.event_name         AS EventName,
        d.event_name         AS EventDomainName,
        o.subject_entity     AS SubjectEntity,
        o.subject_record_id  AS SubjectRecordId,
        o.subject_label      AS SubjectLabel,
        o.occurred_dt        AS OccurredOn,
        o.raise_source       AS RaiseSource,
        o.remarks            AS Remarks,
        o.status             AS Status,
        o.entered_by         AS RaisedBy,
        cnt.TotalItems       AS TotalItems,
        cnt.CompletedItems   AS CompletedItems,
        cnt.TotalItems - cnt.CompletedItems AS PendingItems,
        cnt.FailedItems      AS FailedItems,
        CASE WHEN cnt.TotalItems = 0 THEN 0
             ELSE CAST(ROUND(100.0 * cnt.CompletedItems / cnt.TotalItems, 0) AS INT)
        END                  AS CompletionPercent
    FROM GRAC_New.assurance_event_occurrence o
    JOIN GRAC_New.event_type_master e ON e.event_type_id = o.event_type_id
    LEFT JOIN GRAC_New.event_type_master d ON d.event_type_id = e.parent_event_type_id
    CROSS APPLY (
        SELECT COUNT(1) AS TotalItems,
               SUM(CASE WHEN i.status = N'Completed' THEN 1 ELSE 0 END) AS CompletedItems,
               SUM(CASE WHEN i.response_value = N'Fail' THEN 1 ELSE 0 END) AS FailedItems
        FROM GRAC_New.assurance_checklist_item i
        WHERE i.occurrence_id = o.occurrence_id
    ) cnt
    WHERE (@p_id = 0 OR o.occurrence_id = @p_id)
      AND (@p_status = N'' OR o.status = @p_status)
      AND (@p_search = N''
           OR o.subject_label LIKE N'%' + @p_search + N'%'
           OR e.event_name    LIKE N'%' + @p_search + N'%')
    ORDER BY CASE WHEN o.status = N'Open' THEN 0 ELSE 1 END, o.occurred_dt DESC, o.occurrence_id DESC;
END
GO

-- =====================================================================
-- 3. sp_cm_assurance_checklist_list
--    Items for one occurrence.  Reads the SNAPSHOT columns, never the live
--    obligation -- editing a rule must not change a checklist already
--    raised against it.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_checklist_list
    @p_occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        i.checklist_item_id            AS Id,
        i.checklist_item_id            AS ChecklistItemId,
        i.occurrence_id                AS OccurrenceId,
        i.obligation_id                AS ObligationId,
        i.assurance_spec_id            AS AssuranceSpecId,
        i.obligation_name_snapshot     AS ObligationName,
        i.verification_method_snapshot AS VerificationMethod,
        i.assurance_party_snapshot     AS AssuranceParty,
        i.scope_snapshot               AS Scope,
        i.due_dt                       AS DueOn,
        i.status                       AS Status,
        i.response_value               AS ResponseValue,
        i.remarks                      AS Remarks,
        i.completed_by                 AS CompletedBy,
        i.completed_dt                 AS CompletedOn,
        COALESCE((
            SELECT ev.checklist_evidence_id AS ChecklistEvidenceId,
                   ev.evidence_type_id      AS EvidenceTypeId,
                   et.evidence_type_name    AS EvidenceType,
                   ev.file_name             AS FileName,
                   ev.file_reference        AS FileReference,
                   ev.remarks               AS Remarks
            FROM GRAC_New.assurance_checklist_evidence ev
            LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = ev.evidence_type_id
            WHERE ev.checklist_item_id = i.checklist_item_id AND ev.status = N'Active'
            ORDER BY ev.checklist_evidence_id
            FOR JSON PATH
        ), N'[]')                      AS EvidenceJson
    FROM GRAC_New.assurance_checklist_item i
    WHERE i.occurrence_id = @p_occurrence_id
    ORDER BY i.status DESC, i.checklist_item_id;
END
GO

-- =====================================================================
-- 4. sp_cm_assurance_checklist_complete
--    Records a result.  Also closes the occurrence when the last pending
--    item is answered, so "Open" always means "something is still owed".
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_checklist_complete
    @p_checklist_item_id BIGINT,
    @p_response_value    NVARCHAR(20),
    @p_remarks           NVARCHAR(MAX) = NULL,
    @p_usr_id            NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_checklist_item_id IS NULL OR @p_checklist_item_id <= 0
        THROW 52910, 'sp_cm_assurance_checklist_complete: checklist item is required.', 1;
    IF @p_response_value NOT IN (N'Pass', N'Fail', N'Not Applicable')
        THROW 52911, 'sp_cm_assurance_checklist_complete: response must be Pass, Fail or Not Applicable.', 1;

    DECLARE @occurrence_id BIGINT, @occurrence_status NVARCHAR(30);
    SELECT @occurrence_id = i.occurrence_id, @occurrence_status = o.status
    FROM GRAC_New.assurance_checklist_item i
    JOIN GRAC_New.assurance_event_occurrence o ON o.occurrence_id = i.occurrence_id
    WHERE i.checklist_item_id = @p_checklist_item_id;

    IF @occurrence_id IS NULL
        THROW 52912, 'sp_cm_assurance_checklist_complete: checklist item not found.', 1;
    IF @occurrence_status = N'Cancelled'
        THROW 52913, 'sp_cm_assurance_checklist_complete: this checklist has been cancelled.', 1;

    -- A Fail should be explained.  Cheap to require, and a bare Fail with no
    -- context is worthless to whoever reads the audit trail later.
    IF @p_response_value = N'Fail' AND NULLIF(LTRIM(RTRIM(@p_remarks)), N'') IS NULL
        THROW 52914, 'sp_cm_assurance_checklist_complete: remarks are required when the result is Fail.', 1;

    BEGIN TRAN;

    UPDATE GRAC_New.assurance_checklist_item
    SET status         = N'Completed',
        response_value = @p_response_value,
        remarks        = @p_remarks,
        completed_by   = @p_usr_id,
        completed_dt   = SYSUTCDATETIME(),
        updated_by     = @p_usr_id,
        updated_dt     = SYSUTCDATETIME()
    WHERE checklist_item_id = @p_checklist_item_id;

    -- Close the occurrence once nothing is pending.
    IF NOT EXISTS (SELECT 1 FROM GRAC_New.assurance_checklist_item
                   WHERE occurrence_id = @occurrence_id AND status = N'Pending')
        UPDATE GRAC_New.assurance_event_occurrence
        SET status = N'Completed', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE occurrence_id = @occurrence_id AND status = N'Open';

    COMMIT;

    SELECT @p_checklist_item_id AS Id, @occurrence_id AS OccurrenceId;
END
GO

-- =====================================================================
-- 5. sp_cm_assurance_checklist_reopen
--    Corrects a mistake.  Reopening also reopens the occurrence, otherwise
--    a Completed occurrence could contain a Pending item.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_checklist_reopen
    @p_checklist_item_id BIGINT,
    @p_usr_id            NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    DECLARE @occurrence_id BIGINT =
        (SELECT occurrence_id FROM GRAC_New.assurance_checklist_item
         WHERE checklist_item_id = @p_checklist_item_id);

    IF @occurrence_id IS NULL
        THROW 52912, 'sp_cm_assurance_checklist_reopen: checklist item not found.', 1;

    BEGIN TRAN;

    -- The completion CHECK constraint requires all three fields to clear
    -- together with the status.
    UPDATE GRAC_New.assurance_checklist_item
    SET status         = N'Pending',
        response_value = NULL,
        completed_by   = NULL,
        completed_dt   = NULL,
        updated_by     = @p_usr_id,
        updated_dt     = SYSUTCDATETIME()
    WHERE checklist_item_id = @p_checklist_item_id;

    UPDATE GRAC_New.assurance_event_occurrence
    SET status = N'Open', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
    WHERE occurrence_id = @occurrence_id AND status = N'Completed';

    COMMIT;

    SELECT @p_checklist_item_id AS Id, @occurrence_id AS OccurrenceId;
END
GO

-- =====================================================================
-- 6. sp_cm_assurance_occurrence_cancel
--    Raised in error.  Cancel rather than delete -- the fact that someone
--    raised it is itself part of the trail.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_occurrence_cancel
    @p_occurrence_id BIGINT,
    @p_remarks       NVARCHAR(MAX) = NULL,
    @p_usr_id        NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@p_remarks)), N'') IS NULL
        THROW 52915, 'sp_cm_assurance_occurrence_cancel: a reason is required to cancel a checklist.', 1;

    UPDATE GRAC_New.assurance_event_occurrence
    SET status     = N'Cancelled',
        remarks    = CONCAT(COALESCE(remarks + N' | ', N''), N'Cancelled: ', @p_remarks),
        updated_by = @p_usr_id,
        updated_dt = SYSUTCDATETIME()
    WHERE occurrence_id = @p_occurrence_id AND status <> N'Cancelled';

    SELECT @p_occurrence_id AS Id;
END
GO

-- =====================================================================
-- 7. sp_cm_assurance_event_subjects
--    Selectable subjects for a chosen event type, resolved through the
--    register named by event_type_master.subject_entity.
--
--    Only cm_user is implemented -- it is the only register this database
--    has.  A new domain adds a branch here; until then an unknown register
--    returns an empty set rather than failing, so the picker degrades
--    quietly instead of breaking the screen.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_event_subjects
    @p_event_type_id BIGINT,
    @p_search        NVARCHAR(250) = N''
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @subject_entity NVARCHAR(100) =
        (SELECT subject_entity FROM GRAC_New.event_type_master WHERE event_type_id = @p_event_type_id);

    IF @subject_entity = N'cm_user'
        SELECT u.user_id AS Id,
               u.user_id AS SubjectRecordId,
               N'cm_user' AS SubjectEntity,
               CONCAT(u.user_name, N' (', u.login_id, N')') AS SubjectLabel
        FROM GRAC_New.cm_user u
        WHERE u.status = N'Active'
          AND (@p_search = N''
               OR u.user_name LIKE N'%' + @p_search + N'%'
               OR u.login_id  LIKE N'%' + @p_search + N'%')
        ORDER BY u.user_name;
    ELSE
        SELECT CAST(NULL AS BIGINT) AS Id,
               CAST(NULL AS BIGINT) AS SubjectRecordId,
               CAST(NULL AS NVARCHAR(100)) AS SubjectEntity,
               CAST(NULL AS NVARCHAR(300)) AS SubjectLabel
        WHERE 1 = 0;
END
GO

-- =====================================================================
-- 8. Read dispatcher.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_get_assurance_runtime
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

    IF @p_entity_type = N'assurance-occurrences'
    BEGIN
        EXEC dbo.sp_cm_assurance_occurrence_list
             @p_id = @p_id, @p_search = @p_search, @p_status = @p_status;
        RETURN;
    END

    IF @p_entity_type = N'assurance-checklist'
    BEGIN
        -- @p_id is the OCCURRENCE, not the item: the screen always loads a
        -- whole checklist.  Mirrors how the taxonomy dispatcher treats
        -- obligationId.
        IF @p_id IS NULL OR @p_id <= 0
        BEGIN
            RAISERROR('cm_get_assurance_runtime: occurrence id is required for assurance-checklist.', 16, 1);
            RETURN;
        END
        EXEC dbo.sp_cm_assurance_checklist_list @p_occurrence_id = @p_id;
        RETURN;
    END

    IF @p_entity_type = N'event-subjects'
    BEGIN
        DECLARE @evt BIGINT =
            COALESCE(TRY_CAST(JSON_VALUE(@p_payload, '$.eventTypeId') AS BIGINT), @p_id);
        IF @evt IS NULL OR @evt <= 0
        BEGIN
            RAISERROR('cm_get_assurance_runtime: eventTypeId is required for event-subjects.', 16, 1);
            RETURN;
        END
        EXEC dbo.sp_cm_assurance_event_subjects @p_event_type_id = @evt, @p_search = @p_search;
        RETURN;
    END

    RAISERROR('cm_get_assurance_runtime: unknown entity_type %s.', 16, 1, @p_entity_type);
END
GO

-- =====================================================================
-- 9. Write dispatcher.
--
--    The browser gateway hardcodes Action = 'SAVE', so the real intent is
--    tunnelled in the payload as $._action -- same convention as 030.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_manage_assurance_runtime
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT        = 0,
    @p_search      NVARCHAR(250) = N'',
    @p_status      NVARCHAR(30)  = N'',
    @p_payload     NVARCHAR(MAX) = N'{}',
    @p_usr_id      NVARCHAR(100) = N''
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF NULLIF(@p_usr_id, N'') IS NULL SET @p_usr_id = N'system';

    DECLARE @effective_action NVARCHAR(30) =
        COALESCE(NULLIF(JSON_VALUE(@p_payload, '$._action'), N''), @p_action);

    IF @effective_action IN (N'RAISE', N'SAVE') AND @p_entity_type = N'assurance-occurrences'
    BEGIN
        DECLARE @evt_id     BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.eventTypeId') AS BIGINT);
        DECLARE @sub_entity NVARCHAR(100) = JSON_VALUE(@p_payload, '$.subjectEntity');
        DECLARE @sub_id     BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.subjectRecordId') AS BIGINT);
        DECLARE @sub_label  NVARCHAR(300) = JSON_VALUE(@p_payload, '$.subjectLabel');
        DECLARE @occ_dt     DATETIME2(3)  = TRY_CAST(JSON_VALUE(@p_payload, '$.occurredOn') AS DATETIME2(3));
        DECLARE @occ_rem    NVARCHAR(MAX) = JSON_VALUE(@p_payload, '$.remarks');

        EXEC dbo.sp_cm_assurance_occurrence_raise
             @p_event_type_id     = @evt_id,
             @p_subject_entity    = @sub_entity,
             @p_subject_record_id = @sub_id,
             @p_subject_label     = @sub_label,
             @p_occurred_dt       = @occ_dt,
             @p_raise_source      = N'Manual',
             @p_remarks           = @occ_rem,
             @p_usr_id            = @p_usr_id;
        RETURN;
    END

    IF @effective_action IN (N'CANCEL', N'RETIRE') AND @p_entity_type = N'assurance-occurrences'
    BEGIN
        DECLARE @cancel_remarks NVARCHAR(MAX) = JSON_VALUE(@p_payload, '$.remarks');
        EXEC dbo.sp_cm_assurance_occurrence_cancel
             @p_occurrence_id = @p_id, @p_remarks = @cancel_remarks, @p_usr_id = @p_usr_id;
        RETURN;
    END

    IF @p_entity_type = N'assurance-checklist'
    BEGIN
        DECLARE @item_id BIGINT =
            COALESCE(TRY_CAST(JSON_VALUE(@p_payload, '$.checklistItemId') AS BIGINT), @p_id);

        IF @effective_action = N'REOPEN'
        BEGIN
            EXEC dbo.sp_cm_assurance_checklist_reopen
                 @p_checklist_item_id = @item_id, @p_usr_id = @p_usr_id;
            RETURN;
        END

        IF @effective_action IN (N'COMPLETE', N'SAVE')
        BEGIN
            DECLARE @response NVARCHAR(20)  = JSON_VALUE(@p_payload, '$.responseValue');
            DECLARE @item_rem NVARCHAR(MAX) = JSON_VALUE(@p_payload, '$.remarks');
            EXEC dbo.sp_cm_assurance_checklist_complete
                 @p_checklist_item_id = @item_id,
                 @p_response_value    = @response,
                 @p_remarks           = @item_rem,
                 @p_usr_id            = @p_usr_id;
            RETURN;
        END
    END

    RAISERROR('cm_manage_assurance_runtime: unsupported action %s for entity_type %s.', 16, 1, @effective_action, @p_entity_type);
END
GO

PRINT '036 complete. Assurance runtime procedures installed:';
PRINT '  raise / list / complete / reopen / cancel + subject picker,';
PRINT '  dispatchers cm_get_assurance_runtime and cm_manage_assurance_runtime.';
PRINT '  All write directly -- no maker-checker, by design (see 035).';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
