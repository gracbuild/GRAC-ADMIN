-- =====================================================================
-- 038 ROLLBACK -- Event-driven Assurance, Phase D SLA and due dates
--
-- Reverses database/038_assurance_sla_due_dates.sql by restoring the 037
-- shapes of everything it re-emitted, then removing the sla_days column:
--
--   1. fn_cm_assurance_specs_for_event   -> 037 (no sla_days)
--   2. sp_cm_assurance_occurrence_raise  -> 037 (no due_dt)
--   3. tr_cm_user_assurance_autoraise    -> 037 (no due_dt)
--   4. sp_cm_assurance_checklist_list    -> 036 (no IsOverdue)
--   5. sp_cm_assurance_occurrence_list   -> 036 (no OverdueItems)
--   6. drop ck_cm_assurance_spec_sla_days and the sla_days column
--
-- Order matters: the procedures must stop referencing sla_days before it is
-- dropped, and the function must be restored before the callers that inline
-- it are recompiled.
--
-- due_dt values already written to assurance_checklist_item are LEFT IN
-- PLACE.  The column predates this migration (035) and the dates are real
-- commitments that were shown to users; erasing them would rewrite history.
-- They simply stop being computed for new checklists.
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- =====================================================================
-- 1. Function -- 037 shape.
-- =====================================================================
CREATE OR ALTER FUNCTION GRAC_New.fn_cm_assurance_specs_for_event(@p_event_type_id BIGINT)
RETURNS TABLE
AS
RETURN
(
    SELECT
        s.assurance_spec_id,
        s.obligation_id,
        s.verification_method,
        s.assurance_party,
        s.scope,
        LEFT(COALESCE(ro.obligation_name, ro.obligation_text,
                      CONCAT(N'Obligation #', ro.obligation_id)), 500) AS obligation_name
    FROM GRAC_New.obligation_assurance_spec s
    JOIN GRAC_New.requirement_obligation ro
      ON ro.obligation_id = s.obligation_id
     AND ro.status = N'Active'
    WHERE s.status        = N'Active'
      AND s.trigger_mode  = N'EventDriven'
      AND s.event_type_id = @p_event_type_id
);
GO

-- =====================================================================
-- 2. Manual raise -- 037 shape (no due_dt).
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
        assurance_party_snapshot, scope_snapshot,
        status, entered_by)
    SELECT @occurrence_id, m.obligation_id, m.assurance_spec_id,
           m.obligation_name, m.verification_method,
           m.assurance_party, m.scope,
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

-- =====================================================================
-- 3. Trigger -- 037 shape (no due_dt).
-- =====================================================================
CREATE OR ALTER TRIGGER GRAC_New.tr_cm_user_assurance_autoraise
ON GRAC_New.cm_user
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF NOT EXISTS (
        SELECT 1 FROM GRAC_New.reference_option
        WHERE option_group = N'assurance-settings'
          AND option_value = N'people-autoraise'
          AND status = N'Active')
        RETURN;

    DECLARE @todo TABLE(
        user_id       BIGINT        NOT NULL,
        event_code    NVARCHAR(60)  NOT NULL,
        subject_label NVARCHAR(300) NOT NULL,
        PRIMARY KEY (user_id, event_code));

    INSERT @todo(user_id, event_code, subject_label)
    SELECT i.user_id, N'PEOPLE_ONBOARDING',
           LEFT(CONCAT(i.user_name, N' (', i.login_id, N')'), 300)
    FROM inserted i
    LEFT JOIN deleted d ON d.user_id = i.user_id
    WHERE i.status = N'Active'
      AND (d.user_id IS NULL OR d.status <> N'Active');

    INSERT @todo(user_id, event_code, subject_label)
    SELECT i.user_id, N'PEOPLE_OFFBOARDING',
           LEFT(CONCAT(i.user_name, N' (', i.login_id, N')'), 300)
    FROM inserted i
    JOIN deleted d ON d.user_id = i.user_id
    WHERE d.status = N'Active'
      AND i.status <> N'Active';

    IF NOT EXISTS (SELECT 1 FROM @todo) RETURN;

    DECLARE @raised TABLE(
        occurrence_id BIGINT NOT NULL,
        event_type_id BIGINT NOT NULL);

    INSERT GRAC_New.assurance_event_occurrence(
        event_type_id, subject_entity, subject_record_id, subject_label,
        occurred_dt, raise_source, remarks, status, entered_by)
    OUTPUT inserted.occurrence_id, inserted.event_type_id INTO @raised
    SELECT e.event_type_id, N'cm_user', t.user_id, t.subject_label,
           SYSUTCDATETIME(), N'System',
           N'Raised automatically from User Management.', N'Open', N'system'
    FROM @todo t
    JOIN GRAC_New.event_type_master e
      ON e.event_code = t.event_code
     AND e.status = N'Active'
    JOIN GRAC_New.event_type_master p
      ON p.event_type_id = e.parent_event_type_id
     AND p.status = N'Active'
    WHERE NOT EXISTS (
        SELECT 1 FROM GRAC_New.assurance_event_occurrence o
        WHERE o.event_type_id     = e.event_type_id
          AND o.subject_entity    = N'cm_user'
          AND o.subject_record_id = t.user_id
          AND o.status            = N'Open');

    IF NOT EXISTS (SELECT 1 FROM @raised) RETURN;

    INSERT GRAC_New.assurance_checklist_item(
        occurrence_id, obligation_id, assurance_spec_id,
        obligation_name_snapshot, verification_method_snapshot,
        assurance_party_snapshot, scope_snapshot,
        status, entered_by)
    SELECT r.occurrence_id, m.obligation_id, m.assurance_spec_id,
           m.obligation_name, m.verification_method,
           m.assurance_party, m.scope,
           N'Pending', N'system'
    FROM @raised r
    CROSS APPLY GRAC_New.fn_cm_assurance_specs_for_event(r.event_type_id) m;
END
GO

-- =====================================================================
-- 4. Checklist read -- 036 shape (no IsOverdue).
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
-- 5. Occurrence read -- 036 shape (no OverdueItems).
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
-- 6. Drop the column.  Existing due_dt values on checklist items are kept.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_cm_assurance_spec_sla_days')
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP CONSTRAINT ck_cm_assurance_spec_sla_days;
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','sla_days') IS NOT NULL
    ALTER TABLE GRAC_New.obligation_assurance_spec DROP COLUMN sla_days;
GO

PRINT '038 rollback complete.';
PRINT '  sla_days removed; procedures and trigger restored to their 036 / 037 shapes.';
PRINT '  due_dt values already on checklist items were intentionally left in place.';
GO
