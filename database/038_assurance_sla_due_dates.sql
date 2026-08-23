-- =====================================================================
-- 038 -- Event-driven Assurance, Phase D: SLA and due dates
--
-- assurance_checklist_item.due_dt has existed since 035 and the grid already
-- reads it, but nothing ever populated it.  This migration closes that loop:
--
--     * obligation_assurance_spec.sla_days                   (NEW)
--     * fn_cm_assurance_specs_for_event                      carries it
--     * sp_cm_assurance_occurrence_raise                     computes due_dt
--     * tr_cm_user_assurance_autoraise                       computes due_dt
--     * sp_cm_assurance_checklist_list                       projects overdue
--     * sp_cm_assurance_occurrence_list                      counts overdue
--
-- WHY sla_days AND NOT A DUE DATE ON THE OBLIGATION
-- -------------------------------------------------
-- The rule cannot carry an absolute date -- it applies to every future
-- occurrence.  What it carries is an INTERVAL ("complete within 7 days of the
-- event"), which the runtime layer resolves against occurred_dt into a
-- concrete due_dt per checklist item.  That resolved date is then frozen on
-- the item, in the same spirit as the wording snapshots: changing the SLA
-- next year must not silently re-date a checklist raised last year.
--
-- WHY IT SITS ON THE SPEC AND NOT ON THE EVENT
-- --------------------------------------------
-- Two assurances raised by the same onboarding event can legitimately have
-- different urgency -- "issue laptop" in 2 days, "complete security training"
-- in 30.  Putting the SLA on the event type would force them to share one.
--
-- NULL means no deadline.  Deliberately not defaulted to a number: inventing
-- a deadline for every historical spec would create fake overdue items on the
-- day this ships.
--
-- Preflight: 037 (the shared TVF and the trigger this re-emits).
--
-- Rollback: database/038_assurance_sla_due_dates_rollback.sql
--
-- Safe to re-run.  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.fn_cm_assurance_specs_for_event','IF') IS NULL
BEGIN
    RAISERROR('038 preflight failed: run 037 (auto-raise + shared TVF) first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sla_days on the spec.
--    Small positive integer or NULL.  A CHECK rather than an unsigned type
--    because T-SQL has none, and a negative SLA would produce a due date
--    before the event.
-- =====================================================================
IF COL_LENGTH('GRAC_New.obligation_assurance_spec','sla_days') IS NULL
BEGIN
    ALTER TABLE GRAC_New.obligation_assurance_spec ADD sla_days INT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_cm_assurance_spec_sla_days')
BEGIN
    ALTER TABLE GRAC_New.obligation_assurance_spec WITH CHECK
        ADD CONSTRAINT ck_cm_assurance_spec_sla_days
            CHECK (sla_days IS NULL OR (sla_days >= 0 AND sla_days <= 3650));
END
GO

-- =====================================================================
-- 2. Shared matching rule -- now carries the SLA.
--    Re-emitted from 037 with sla_days added, so both the manual and the
--    automatic path pick it up without duplicating the computation.
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
        s.sla_days,
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
-- =====================================================================
-- 3. Manual raise -- INTENTIONALLY NOT EMITTED HERE.
--
--    This migration used to re-emit sp_cm_assurance_occurrence_raise to add
--    the due_dt expression.  It no longer does, and that is deliberate.
--
--    WHY
--    ---
--    Migration 040 owns this procedure.  It re-emits the SAME body with one
--    correction: the duplicate-raise guard COMMITs instead of ROLLBACKs,
--    because ROLLBACK is illegal inside INSERT ... EXEC (Msg 3916, found by
--    039 check G1).
--
--    While BOTH files emitted the procedure, 038 shipped the OLD body.  Every
--    file here is documented "safe to re-run", and individually that was true
--    -- but re-running 038 on its own silently reverted 040's fix and put the
--    3916 bug back into production.  A migration that is safe alone but unsafe
--    in combination is worse than one that is plainly unsafe, because nothing
--    warns you.
--
--    One procedure, one owning migration.  040 is the owner.
--
--    CONSEQUENCE FOR A FRESH INSTALL: between 038 and 040 the procedure is
--    still 036's version, without due_dt.  040 always follows 038 in the
--    documented apply order, so this window closes immediately.  The SLA
--    columns and fn_cm_assurance_specs_for_event (section 2 above) are still
--    established here, which is what 040 depends on.
-- =====================================================================

-- =====================================================================
-- 4. Auto-raise trigger -- same due_dt computation.
--    Re-emitted from 037 with the due_dt expression added.  Everything else,
--    including the "cannot fail" guarantees, is unchanged: DATEADD on a
--    guarded INT introduces no new failure mode.
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

    -- occurred_dt is captured once so every item in the batch dates from the
    -- same instant -- otherwise two items in one checklist could differ by
    -- milliseconds and, at a day boundary, by a whole day of SLA.
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

    DECLARE @raised TABLE(
        occurrence_id BIGINT       NOT NULL,
        event_type_id BIGINT       NOT NULL,
        occurred_dt   DATETIME2(3) NOT NULL);

    INSERT GRAC_New.assurance_event_occurrence(
        event_type_id, subject_entity, subject_record_id, subject_label,
        occurred_dt, raise_source, remarks, status, entered_by)
    OUTPUT inserted.occurrence_id, inserted.event_type_id, inserted.occurred_dt INTO @raised
    SELECT e.event_type_id, N'cm_user', t.user_id, t.subject_label,
           @now, N'System',
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
        assurance_party_snapshot, scope_snapshot, due_dt,
        status, entered_by)
    SELECT r.occurrence_id, m.obligation_id, m.assurance_spec_id,
           m.obligation_name, m.verification_method,
           m.assurance_party, m.scope,
           CASE WHEN m.sla_days IS NULL THEN NULL
                ELSE DATEADD(DAY, m.sla_days, r.occurred_dt) END,
           N'Pending', N'system'
    FROM @raised r
    CROSS APPLY GRAC_New.fn_cm_assurance_specs_for_event(r.event_type_id) m;
END
GO

-- =====================================================================
-- 5. Checklist read -- project overdue state.
--
--    IsOverdue is computed server-side rather than in the browser so the
--    definition of "overdue" cannot drift between screens, and so it is
--    always measured against database time rather than the client clock.
--    A completed item is never overdue, whatever its due date.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_checklist_list
    @p_occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

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
        CAST(CASE WHEN i.status = N'Pending' AND i.due_dt IS NOT NULL AND i.due_dt < @now
                  THEN 1 ELSE 0 END AS BIT) AS IsOverdue,
        CASE WHEN i.status = N'Pending' AND i.due_dt IS NOT NULL
             THEN DATEDIFF(DAY, @now, i.due_dt) END AS DaysRemaining,
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
    -- Overdue first, then the rest of the pending work, then completed.
    ORDER BY CASE WHEN i.status = N'Pending' AND i.due_dt IS NOT NULL AND i.due_dt < @now THEN 0
                  WHEN i.status = N'Pending' THEN 1
                  ELSE 2 END,
             i.due_dt,
             i.checklist_item_id;
END
GO

-- =====================================================================
-- 6. Occurrence read -- overdue count and earliest due date.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_assurance_occurrence_list
    @p_id     BIGINT        = 0,
    @p_search NVARCHAR(250) = N'',
    @p_status NVARCHAR(30)  = N''
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now DATETIME2(3) = SYSUTCDATETIME();

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
        cnt.OverdueItems     AS OverdueItems,
        cnt.NextDueOn        AS NextDueOn,
        CASE WHEN cnt.TotalItems = 0 THEN 0
             ELSE CAST(ROUND(100.0 * cnt.CompletedItems / cnt.TotalItems, 0) AS INT)
        END                  AS CompletionPercent
    FROM GRAC_New.assurance_event_occurrence o
    JOIN GRAC_New.event_type_master e ON e.event_type_id = o.event_type_id
    LEFT JOIN GRAC_New.event_type_master d ON d.event_type_id = e.parent_event_type_id
    CROSS APPLY (
        SELECT COUNT(1) AS TotalItems,
               SUM(CASE WHEN i.status = N'Completed' THEN 1 ELSE 0 END) AS CompletedItems,
               SUM(CASE WHEN i.response_value = N'Fail' THEN 1 ELSE 0 END) AS FailedItems,
               SUM(CASE WHEN i.status = N'Pending' AND i.due_dt IS NOT NULL AND i.due_dt < @now
                        THEN 1 ELSE 0 END) AS OverdueItems,
               MIN(CASE WHEN i.status = N'Pending' THEN i.due_dt END) AS NextDueOn
        FROM GRAC_New.assurance_checklist_item i
        WHERE i.occurrence_id = o.occurrence_id
    ) cnt
    WHERE (@p_id = 0 OR o.occurrence_id = @p_id)
      AND (@p_status = N'' OR o.status = @p_status)
      AND (@p_search = N''
           OR o.subject_label LIKE N'%' + @p_search + N'%'
           OR e.event_name    LIKE N'%' + @p_search + N'%')
    -- Overdue work surfaces above merely-open work.
    ORDER BY CASE WHEN o.status = N'Open' AND cnt.OverdueItems > 0 THEN 0
                  WHEN o.status = N'Open' THEN 1
                  ELSE 2 END,
             o.occurred_dt DESC, o.occurrence_id DESC;
END
GO

-- =====================================================================
-- 7. Carry sla_days through the assurance get / save path.
--    Re-emitted from 034 with the one new field added.
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
        s.trigger_mode            AS TriggerMode,
        mode.option_label         AS TriggerModeLabel,
        s.event_type_id           AS EventTypeId,
        evt.event_code            AS EventCode,
        evt.event_name            AS EventName,
        evt.parent_event_type_id  AS EventDomainId,
        dom.event_code            AS EventDomainCode,
        dom.event_name            AS EventDomainName,
        evt.subject_entity        AS EventSubjectEntity,
        s.sla_days                AS SlaDays,
        s.remarks                 AS Remarks,
        s.status                  AS Status,
        s.entered_by              AS EnteredBy,
        s.entered_dt              AS EnteredDt,
        s.updated_by              AS UpdatedBy,
        s.updated_dt              AS UpdatedDt
    FROM GRAC_New.obligation_assurance_spec s
    LEFT JOIN GRAC_New.reference_option freq
        ON freq.reference_option_id = s.assurance_frequency_id
    LEFT JOIN GRAC_New.reference_option mode
        ON mode.option_group = N'assurance-trigger-modes'
       AND mode.option_value = s.trigger_mode
    LEFT JOIN GRAC_New.event_type_master evt
        ON evt.event_type_id = s.event_type_id
    LEFT JOIN GRAC_New.event_type_master dom
        ON dom.event_type_id = evt.parent_event_type_id
    WHERE s.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR s.status = N'Active')
    ORDER BY s.entered_dt DESC, s.assurance_spec_id DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_assurance_save
    @p_id                     BIGINT       = 0,
    @p_obligation_id          BIGINT,
    @p_verification_method    NVARCHAR(500),
    @p_scope                  NVARCHAR(500) = NULL,
    @p_assurance_frequency_id BIGINT        = NULL,
    @p_assurance_party        NVARCHAR(250) = NULL,
    @p_trigger_mode           NVARCHAR(20)  = NULL,
    @p_event_type_id          BIGINT        = NULL,
    @p_sla_days               INT           = NULL,
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

    SET @p_trigger_mode = NULLIF(LTRIM(RTRIM(@p_trigger_mode)), N'');

    IF @p_trigger_mode IS NOT NULL
       AND NOT EXISTS(
            SELECT 1 FROM GRAC_New.reference_option ro
            WHERE ro.option_group = N'assurance-trigger-modes'
              AND ro.option_value = @p_trigger_mode
              AND ro.status = N'Active')
        THROW 52833, 'sp_cm_obligation_assurance_save: invalid assurance trigger mode.', 1;

    IF @p_trigger_mode = N'EventDriven'
    BEGIN
        IF @p_event_type_id IS NULL
            THROW 52834, 'sp_cm_obligation_assurance_save: an event is required for event-driven assurance.', 1;

        IF NOT EXISTS(
            SELECT 1
            FROM GRAC_New.event_type_master e
            JOIN GRAC_New.event_type_master p ON p.event_type_id = e.parent_event_type_id
            WHERE e.event_type_id = @p_event_type_id
              AND e.status = N'Active'
              AND p.status = N'Active')
            THROW 52835, 'sp_cm_obligation_assurance_save: event must be an active event under an active domain.', 1;
    END
    ELSE
    BEGIN
        SET @p_event_type_id = NULL;
        -- An SLA is measured from an event, so it is meaningless on a
        -- scheduled spec.  Clear rather than throw, so switching modes
        -- cleans up after itself.
        SET @p_sla_days = NULL;
    END

    IF @p_sla_days IS NOT NULL AND (@p_sla_days < 0 OR @p_sla_days > 3650)
        THROW 52836, 'sp_cm_obligation_assurance_save: due within must be between 0 and 3650 days.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, scope, assurance_frequency_id,
            assurance_party, trigger_mode, event_type_id, sla_days, remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_verification_method, @p_scope, @p_assurance_frequency_id,
               @p_assurance_party, @p_trigger_mode, @p_event_type_id, @p_sla_days, @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_assurance_spec
        SET verification_method     = @p_verification_method,
            scope                   = @p_scope,
            assurance_frequency_id  = @p_assurance_frequency_id,
            assurance_party         = @p_assurance_party,
            trigger_mode            = @p_trigger_mode,
            event_type_id           = @p_event_type_id,
            sla_days                = @p_sla_days,
            remarks                 = @p_remarks,
            status                  = @p_status,
            updated_by              = @p_usr_id,
            updated_dt              = SYSUTCDATETIME()
        WHERE assurance_spec_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- 8. Dispatcher -- forward slaDays on the obligation-assurance branch.
--    Only that branch differs from 034; re-emitted in full because
--    CREATE OR ALTER replaces the whole procedure.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.cm_manage_obligation_taxonomy
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

    DECLARE @obligation_id BIGINT =
        TRY_CAST(JSON_VALUE(@p_payload, '$.obligationId') AS BIGINT);

    IF @p_entity_type = N'obligation-type-assignment'
       OR (@p_entity_type = N'obligation-types' AND @effective_action = N'ASSIGN_TYPE')
    BEGIN
        DECLARE @type_code NVARCHAR(40) = JSON_VALUE(@p_payload, '$.typeCode');
        IF @obligation_id IS NULL OR @obligation_id <= 0
        BEGIN
            RAISERROR('cm_manage_obligation_taxonomy: obligationId required for ASSIGN_TYPE.', 16, 1);
            RETURN;
        END
        EXEC dbo.sp_cm_obligation_type_assign
             @p_obligation_id = @obligation_id,
             @p_type_code     = @type_code,
             @p_usr_id        = @p_usr_id;
        RETURN;
    END

    IF @p_entity_type = N'obligation-evidence-links'
    BEGIN
        DECLARE @obligation_evidence_id BIGINT =
            TRY_CAST(JSON_VALUE(@p_payload, '$.obligationEvidenceId') AS BIGINT);
        DECLARE @link_remarks NVARCHAR(500) = JSON_VALUE(@p_payload, '$.remarks');
        IF @obligation_id IS NULL OR @obligation_id <= 0
        BEGIN
            RAISERROR('cm_manage_obligation_taxonomy: obligationId required for evidence link ops.', 16, 1);
            RETURN;
        END
        IF @obligation_evidence_id IS NULL OR @obligation_evidence_id <= 0
        BEGIN
            RAISERROR('cm_manage_obligation_taxonomy: obligationEvidenceId required for evidence link ops.', 16, 1);
            RETURN;
        END

        IF @effective_action IN (N'ATTACH', N'SAVE')
            EXEC dbo.sp_cm_obligation_evidence_link_attach
                 @p_obligation_id          = @obligation_id,
                 @p_obligation_evidence_id = @obligation_evidence_id,
                 @p_remarks                = @link_remarks,
                 @p_usr_id                 = @p_usr_id;
        ELSE IF @effective_action IN (N'DETACH', N'RETIRE', N'DELETE')
            EXEC dbo.sp_cm_obligation_evidence_link_detach
                 @p_obligation_id          = @obligation_id,
                 @p_obligation_evidence_id = @obligation_evidence_id,
                 @p_usr_id                 = @p_usr_id;
        ELSE
            RAISERROR('cm_manage_obligation_taxonomy: unsupported action %s for obligation-evidence-links.', 16, 1, @effective_action);
        RETURN;
    END

    IF @obligation_id IS NULL OR @obligation_id <= 0
    BEGIN
        RAISERROR('cm_manage_obligation_taxonomy: obligationId required for typed detail SAVE.', 16, 1);
        RETURN;
    END

    DECLARE @row_remarks NVARCHAR(MAX)  = JSON_VALUE(@p_payload, '$.remarks');
    DECLARE @row_status  NVARCHAR(30)   = COALESCE(NULLIF(JSON_VALUE(@p_payload, '$.status'), N''), N'Active');

    IF @p_entity_type = N'obligation-state'
    BEGIN
        DECLARE @st_attribute NVARCHAR(250) = JSON_VALUE(@p_payload, '$.attribute');
        DECLARE @st_operator  NVARCHAR(40)  = JSON_VALUE(@p_payload, '$.operator');
        DECLARE @st_value     NVARCHAR(250) = JSON_VALUE(@p_payload, '$.value');
        DECLARE @st_unit      NVARCHAR(60)  = JSON_VALUE(@p_payload, '$.unit');
        DECLARE @st_tolerance NVARCHAR(120) = JSON_VALUE(@p_payload, '$.tolerance');
        EXEC dbo.sp_cm_obligation_state_save
             @p_id            = @p_id,
             @p_obligation_id = @obligation_id,
             @p_attribute     = @st_attribute,
             @p_operator      = @st_operator,
             @p_value         = @st_value,
             @p_unit          = @st_unit,
             @p_tolerance     = @st_tolerance,
             @p_remarks       = @row_remarks,
             @p_status        = @row_status,
             @p_usr_id        = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-execution'
    BEGIN
        DECLARE @ex_action              NVARCHAR(500) = JSON_VALUE(@p_payload, '$.action');
        DECLARE @ex_execution_freq_id   BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.executionFrequencyId') AS BIGINT);
        DECLARE @ex_trigger_condition   NVARCHAR(500) = JSON_VALUE(@p_payload, '$.triggerCondition');
        DECLARE @ex_responsible_party   NVARCHAR(250) = JSON_VALUE(@p_payload, '$.responsibleParty');
        DECLARE @ex_due_within          NVARCHAR(120) = JSON_VALUE(@p_payload, '$.dueWithin');
        EXEC dbo.sp_cm_obligation_execution_save
             @p_id                     = @p_id,
             @p_obligation_id          = @obligation_id,
             @p_action                 = @ex_action,
             @p_execution_frequency_id = @ex_execution_freq_id,
             @p_trigger_condition      = @ex_trigger_condition,
             @p_responsible_party      = @ex_responsible_party,
             @p_due_within             = @ex_due_within,
             @p_remarks                = @row_remarks,
             @p_status                 = @row_status,
             @p_usr_id                 = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-assurance'
    BEGIN
        DECLARE @asr_verification_method NVARCHAR(500) = JSON_VALUE(@p_payload, '$.verificationMethod');
        DECLARE @asr_scope               NVARCHAR(500) = JSON_VALUE(@p_payload, '$.scope');
        DECLARE @asr_frequency_id        BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.assuranceFrequencyId') AS BIGINT);
        DECLARE @asr_party               NVARCHAR(250) = JSON_VALUE(@p_payload, '$.assuranceParty');
        DECLARE @asr_trigger_mode        NVARCHAR(20)  = JSON_VALUE(@p_payload, '$.triggerMode');
        DECLARE @asr_event_type_id       BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.eventTypeId') AS BIGINT);
        DECLARE @asr_sla_days            INT           = TRY_CAST(JSON_VALUE(@p_payload, '$.slaDays') AS INT);
        EXEC dbo.sp_cm_obligation_assurance_save
             @p_id                     = @p_id,
             @p_obligation_id          = @obligation_id,
             @p_verification_method    = @asr_verification_method,
             @p_scope                  = @asr_scope,
             @p_assurance_frequency_id = @asr_frequency_id,
             @p_assurance_party        = @asr_party,
             @p_trigger_mode           = @asr_trigger_mode,
             @p_event_type_id          = @asr_event_type_id,
             @p_sla_days               = @asr_sla_days,
             @p_remarks                = @row_remarks,
             @p_status                 = @row_status,
             @p_usr_id                 = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-event-response'
    BEGIN
        DECLARE @evt_trigger_event   NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.triggerEvent');
        DECLARE @evt_response_action NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.responseAction');
        DECLARE @evt_sla_value       INT            = TRY_CAST(JSON_VALUE(@p_payload, '$.slaValue') AS INT);
        DECLARE @evt_sla_unit        NVARCHAR(40)   = JSON_VALUE(@p_payload, '$.slaUnit');
        DECLARE @evt_escalation_path NVARCHAR(250)  = JSON_VALUE(@p_payload, '$.escalationPath');
        EXEC dbo.sp_cm_obligation_event_response_save
             @p_id              = @p_id,
             @p_obligation_id   = @obligation_id,
             @p_trigger_event   = @evt_trigger_event,
             @p_response_action = @evt_response_action,
             @p_sla_value       = @evt_sla_value,
             @p_sla_unit        = @evt_sla_unit,
             @p_escalation_path = @evt_escalation_path,
             @p_remarks         = @row_remarks,
             @p_status          = @row_status,
             @p_usr_id          = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-constraint'
    BEGIN
        DECLARE @cn_prohibited_condition NVARCHAR(500) = JSON_VALUE(@p_payload, '$.prohibitedCondition');
        DECLARE @cn_scope                NVARCHAR(500) = JSON_VALUE(@p_payload, '$.scope');
        DECLARE @cn_exception_policy     NVARCHAR(500) = JSON_VALUE(@p_payload, '$.exceptionPolicy');
        EXEC dbo.sp_cm_obligation_constraint_save
             @p_id                   = @p_id,
             @p_obligation_id        = @obligation_id,
             @p_prohibited_condition = @cn_prohibited_condition,
             @p_scope                = @cn_scope,
             @p_exception_policy     = @cn_exception_policy,
             @p_remarks              = @row_remarks,
             @p_status               = @row_status,
             @p_usr_id               = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-retention'
    BEGIN
        DECLARE @rt_retained_object    NVARCHAR(250) = JSON_VALUE(@p_payload, '$.retainedObject');
        DECLARE @rt_min_value          INT           = TRY_CAST(JSON_VALUE(@p_payload, '$.minRetentionValue') AS INT);
        DECLARE @rt_min_unit           NVARCHAR(40)  = JSON_VALUE(@p_payload, '$.minRetentionUnit');
        DECLARE @rt_max_value          INT           = TRY_CAST(JSON_VALUE(@p_payload, '$.maxRetentionValue') AS INT);
        DECLARE @rt_max_unit           NVARCHAR(40)  = JSON_VALUE(@p_payload, '$.maxRetentionUnit');
        DECLARE @rt_disposal_policy    NVARCHAR(250) = JSON_VALUE(@p_payload, '$.disposalPolicy');
        EXEC dbo.sp_cm_obligation_retention_save
             @p_id                  = @p_id,
             @p_obligation_id       = @obligation_id,
             @p_retained_object     = @rt_retained_object,
             @p_min_retention_value = @rt_min_value,
             @p_min_retention_unit  = @rt_min_unit,
             @p_max_retention_value = @rt_max_value,
             @p_max_retention_unit  = @rt_max_unit,
             @p_disposal_policy     = @rt_disposal_policy,
             @p_remarks             = @row_remarks,
             @p_status              = @row_status,
             @p_usr_id              = @p_usr_id;
        RETURN;
    END

    RAISERROR('cm_manage_obligation_taxonomy: unknown entity_type %s.', 16, 1, @p_entity_type);
END
GO

PRINT '038 complete. Assurance SLA installed:';
PRINT '  obligation_assurance_spec.sla_days added (NULL = no deadline);';
PRINT '  due_dt now computed on both the manual and automatic raise paths;';
PRINT '  checklist and occurrence reads project overdue state and sort by it.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
