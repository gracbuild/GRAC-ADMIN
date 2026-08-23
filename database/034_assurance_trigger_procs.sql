-- =====================================================================
-- 034 -- Event-driven Assurance, Phase A: carry the trigger columns
--
-- 033 added obligation_assurance_spec.trigger_mode and .event_type_id.
-- This migration teaches the read/write path about them:
--
--     * sp_cm_obligation_assurance_get   -- project the new columns
--     * sp_cm_obligation_assurance_save  -- accept and validate them
--     * cm_manage_obligation_taxonomy    -- re-emitted so the
--                                           'obligation-assurance' branch
--                                           forwards the two new payload keys
--
-- Payload contract for entity_type 'obligation-assurance' gains:
--
--     "triggerMode":    <option_value: Scheduled | EventDriven>
--     "eventTypeId":    <event_type_master id, LEAF only>   -- EventDriven only
--
-- Both optional: a spec authored before this feature stays valid with both
-- NULL, matching the CHECK constraint installed by 033.
--
-- Validation lives in the save proc rather than the dispatcher so it applies
-- no matter which caller writes the row -- the composite save, a direct API
-- call, or an approval replay from the bundle procedures.
--
-- Preflight: 033.
--
-- Rollback: database/034_assurance_trigger_procs_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF COL_LENGTH('GRAC_New.obligation_assurance_spec','trigger_mode') IS NULL
BEGIN
    RAISERROR('034 preflight failed: run 033 (event type taxonomy) first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. GET -- project trigger mode and event type, resolved to labels so the
--    form can render without extra lookups.  Parent domain is included
--    because the cascade needs to pre-select Domain before Event on edit.
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
        -- Trigger classification (033).  trigger_mode stores the code; the
        -- label is resolved from reference_option for display only.
        s.trigger_mode            AS TriggerMode,
        mode.option_label         AS TriggerModeLabel,
        s.event_type_id           AS EventTypeId,
        evt.event_code            AS EventCode,
        evt.event_name            AS EventName,
        -- Parent domain: the form pre-selects this before the event on edit.
        evt.parent_event_type_id  AS EventDomainId,
        dom.event_code            AS EventDomainCode,
        dom.event_name            AS EventDomainName,
        evt.subject_entity        AS EventSubjectEntity,
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

-- =====================================================================
-- 2. SAVE -- accept the two new parameters and validate the pairing.
--
--    The CHECK constraint from 033 already guarantees consistency at the
--    storage layer, but a constraint violation surfaces as an opaque 547.
--    These explicit THROWs give the maker a message they can act on.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_assurance_save
    @p_id                     BIGINT       = 0,
    @p_obligation_id          BIGINT,
    @p_verification_method    NVARCHAR(500),
    @p_scope                  NVARCHAR(500) = NULL,
    @p_assurance_frequency_id BIGINT        = NULL,
    @p_assurance_party        NVARCHAR(250) = NULL,
    @p_trigger_mode           NVARCHAR(20)  = NULL,
    @p_event_type_id          BIGINT        = NULL,
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

    -- ---- trigger classification -----------------------------------
    SET @p_trigger_mode = NULLIF(LTRIM(RTRIM(@p_trigger_mode)), N'');

    -- Validated against reference_option so the accepted set stays data-driven
    -- and matches exactly what the dropdown offered.  The CHECK constraint on
    -- the table is the backstop; this gives a message the maker can act on.
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

        -- Must be an ACTIVE LEAF whose domain is also active.  A domain root
        -- is a grouping, not a raisable event.
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
        -- Scheduled, or not yet classified: an event must not be carried.
        -- Null it rather than throwing, so switching a spec from event-driven
        -- back to scheduled cleans up after itself instead of tripping the
        -- CHECK constraint.
        SET @p_event_type_id = NULL;
    END

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_assurance_spec(
            obligation_id, verification_method, scope, assurance_frequency_id,
            assurance_party, trigger_mode, event_type_id, remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_verification_method, @p_scope, @p_assurance_frequency_id,
               @p_assurance_party, @p_trigger_mode, @p_event_type_id, @p_remarks, @p_status, @p_usr_id);
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
-- 3. Dispatcher: forward the two new payload keys.
--
--    Re-emits cm_manage_obligation_taxonomy from its 030 form with ONLY the
--    'obligation-assurance' branch changed.  Everything else -- the $._action
--    override, ASSIGN_TYPE, evidence links, the other five typed branches --
--    is byte-identical to 030.
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

    -- ------------------------------------------------------------------
    -- ASSIGN_TYPE
    -- ------------------------------------------------------------------
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

    -- ------------------------------------------------------------------
    -- Evidence links
    -- ------------------------------------------------------------------
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

    -- ------------------------------------------------------------------
    -- Typed detail SAVE
    -- ------------------------------------------------------------------
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
        -- Trigger classification (033/034).
        DECLARE @asr_trigger_mode        NVARCHAR(20)  = JSON_VALUE(@p_payload, '$.triggerMode');
        DECLARE @asr_event_type_id       BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.eventTypeId') AS BIGINT);
        EXEC dbo.sp_cm_obligation_assurance_save
             @p_id                     = @p_id,
             @p_obligation_id          = @obligation_id,
             @p_verification_method    = @asr_verification_method,
             @p_scope                  = @asr_scope,
             @p_assurance_frequency_id = @asr_frequency_id,
             @p_assurance_party        = @asr_party,
             @p_trigger_mode           = @asr_trigger_mode,
             @p_event_type_id          = @asr_event_type_id,
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

PRINT '034 complete.';
PRINT '  sp_cm_obligation_assurance_get now projects TriggerMode / Event / Domain.';
PRINT '  sp_cm_obligation_assurance_save accepts triggerMode + eventTypeId.';
PRINT '  cm_manage_obligation_taxonomy forwards both payload keys.';
GO

-- Re-enable execution: harmless when the preflight passed (NOEXEC was
-- never switched on), essential when it did not.
SET NOEXEC OFF;
GO
