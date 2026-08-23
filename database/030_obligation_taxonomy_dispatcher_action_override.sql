-- =====================================================================
-- 030 -- Obligation Taxonomy dispatcher: payload _action override
--
-- Bugfix for Phase 2C wiring.  The Control Management Web gateway
-- (ControlManagementGatewayController.Save) hardcodes Action = "SAVE"
-- on every POST /{entityType} call, regardless of what the front-end
-- sends.  That means our typed-obligation intents ATTACH / DETACH /
-- ASSIGN_TYPE never reach cm_manage_obligation_taxonomy's @p_action
-- parameter as anything other than "SAVE".
--
-- The front-end now tunnels the real intent inside the JSON payload
-- as $._action.  This migration re-applies cm_manage_obligation_taxonomy
-- so it prefers the payload-supplied action when present, falling back
-- to @p_action otherwise.  Original entity_type-based routing is
-- unchanged.
--
-- Preflight: 028 sub-procs must exist (same as 029).
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_type_master_list','P') IS NULL
BEGIN
    RAISERROR('030 preflight failed: run 028 (typed sub-procs) before 030.', 16, 1);
    RETURN;
END
GO

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

    -- Effective action: prefer the tunnelled $._action if the browser
    -- gateway squashed the real intent to SAVE.
    DECLARE @effective_action NVARCHAR(30) =
        COALESCE(NULLIF(JSON_VALUE(@p_payload, '$._action'), N''), @p_action);

    DECLARE @obligation_id BIGINT =
        TRY_CAST(JSON_VALUE(@p_payload, '$.obligationId') AS BIGINT);

    -- ------------------------------------------------------------------
    -- ASSIGN_TYPE:  set master.obligation_type_id via sub-proc.
    -- ------------------------------------------------------------------
    IF @p_entity_type = N'obligation-type-assignment'
       OR (@p_entity_type = N'obligation-types' AND @effective_action = N'ASSIGN_TYPE')
    BEGIN
        DECLARE @type_code NVARCHAR(40) = JSON_VALUE(@p_payload, '$.typeCode');
        IF @obligation_id IS NULL OR @obligation_id <= 0
        BEGIN
            RAISERROR('cm_manage_obligation_taxonomy: obligationId is required for type assignment.', 16, 1);
            RETURN;
        END
        EXEC dbo.sp_cm_obligation_type_assign
             @p_obligation_id = @obligation_id,
             @p_type_code     = @type_code,
             @p_usr_id        = @p_usr_id;
        RETURN;
    END

    -- ------------------------------------------------------------------
    -- Evidence links:  SAVE/ATTACH  and  DETACH/RETIRE/DELETE.
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
    -- Typed detail SAVE.  All detail SAVEs require obligationId.
    -- ------------------------------------------------------------------
    IF @obligation_id IS NULL OR @obligation_id <= 0
    BEGIN
        RAISERROR('cm_manage_obligation_taxonomy: obligationId required in payload for %s.', 16, 1, @p_entity_type);
        RETURN;
    END

    DECLARE @row_status  NVARCHAR(30)  =
        COALESCE(NULLIF(LTRIM(RTRIM(JSON_VALUE(@p_payload, '$.status'))), N''), N'Active');
    DECLARE @row_remarks NVARCHAR(MAX) = JSON_VALUE(@p_payload, '$.remarks');

    IF @p_entity_type = N'obligation-state'
    BEGIN
        DECLARE @state_attribute NVARCHAR(250) = JSON_VALUE(@p_payload, '$.attribute');
        DECLARE @state_operator  NVARCHAR(30)  = JSON_VALUE(@p_payload, '$.operator');
        DECLARE @state_value     NVARCHAR(500) = JSON_VALUE(@p_payload, '$.value');
        DECLARE @state_unit      NVARCHAR(50)  = JSON_VALUE(@p_payload, '$.unit');
        DECLARE @state_tolerance NVARCHAR(200) = JSON_VALUE(@p_payload, '$.tolerance');
        EXEC dbo.sp_cm_obligation_state_save
             @p_id            = @p_id,
             @p_obligation_id = @obligation_id,
             @p_attribute     = @state_attribute,
             @p_operator      = @state_operator,
             @p_value         = @state_value,
             @p_unit          = @state_unit,
             @p_tolerance     = @state_tolerance,
             @p_remarks       = @row_remarks,
             @p_status        = @row_status,
             @p_usr_id        = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-execution'
    BEGIN
        DECLARE @exec_action                NVARCHAR(1000) = JSON_VALUE(@p_payload, '$.action');
        DECLARE @exec_frequency_id          BIGINT         = TRY_CAST(JSON_VALUE(@p_payload, '$.executionFrequencyId') AS BIGINT);
        DECLARE @exec_trigger_condition     NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.triggerCondition');
        DECLARE @exec_responsible_party     NVARCHAR(250)  = JSON_VALUE(@p_payload, '$.responsibleParty');
        DECLARE @exec_due_within            NVARCHAR(120)  = JSON_VALUE(@p_payload, '$.dueWithin');
        EXEC dbo.sp_cm_obligation_execution_save
             @p_id                     = @p_id,
             @p_obligation_id          = @obligation_id,
             @p_action                 = @exec_action,
             @p_execution_frequency_id = @exec_frequency_id,
             @p_trigger_condition      = @exec_trigger_condition,
             @p_responsible_party      = @exec_responsible_party,
             @p_due_within             = @exec_due_within,
             @p_remarks                = @row_remarks,
             @p_status                 = @row_status,
             @p_usr_id                 = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-assurance'
    BEGIN
        DECLARE @asr_verification_method    NVARCHAR(500) = JSON_VALUE(@p_payload, '$.verificationMethod');
        DECLARE @asr_scope                  NVARCHAR(500) = JSON_VALUE(@p_payload, '$.scope');
        DECLARE @asr_frequency_id           BIGINT        = TRY_CAST(JSON_VALUE(@p_payload, '$.assuranceFrequencyId') AS BIGINT);
        DECLARE @asr_party                  NVARCHAR(250) = JSON_VALUE(@p_payload, '$.assuranceParty');
        EXEC dbo.sp_cm_obligation_assurance_save
             @p_id                     = @p_id,
             @p_obligation_id          = @obligation_id,
             @p_verification_method    = @asr_verification_method,
             @p_scope                  = @asr_scope,
             @p_assurance_frequency_id = @asr_frequency_id,
             @p_assurance_party        = @asr_party,
             @p_remarks                = @row_remarks,
             @p_status                 = @row_status,
             @p_usr_id                 = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-event-response'
    BEGIN
        DECLARE @evt_trigger_event   NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.triggerEvent');
        DECLARE @evt_response_action NVARCHAR(1000) = JSON_VALUE(@p_payload, '$.responseAction');
        DECLARE @evt_sla_value       INT            = TRY_CAST(JSON_VALUE(@p_payload, '$.slaValue') AS INT);
        DECLARE @evt_sla_unit        NVARCHAR(30)   = JSON_VALUE(@p_payload, '$.slaUnit');
        DECLARE @evt_escalation      NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.escalationPath');
        EXEC dbo.sp_cm_obligation_event_response_save
             @p_id              = @p_id,
             @p_obligation_id   = @obligation_id,
             @p_trigger_event   = @evt_trigger_event,
             @p_response_action = @evt_response_action,
             @p_sla_value       = @evt_sla_value,
             @p_sla_unit        = @evt_sla_unit,
             @p_escalation_path = @evt_escalation,
             @p_remarks         = @row_remarks,
             @p_status          = @row_status,
             @p_usr_id          = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-constraint'
    BEGIN
        DECLARE @cns_prohibited_condition NVARCHAR(1000) = JSON_VALUE(@p_payload, '$.prohibitedCondition');
        DECLARE @cns_scope                NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.scope');
        DECLARE @cns_exception_policy     NVARCHAR(500)  = JSON_VALUE(@p_payload, '$.exceptionPolicy');
        EXEC dbo.sp_cm_obligation_constraint_save
             @p_id                   = @p_id,
             @p_obligation_id        = @obligation_id,
             @p_prohibited_condition = @cns_prohibited_condition,
             @p_scope                = @cns_scope,
             @p_exception_policy     = @cns_exception_policy,
             @p_remarks              = @row_remarks,
             @p_status               = @row_status,
             @p_usr_id               = @p_usr_id;
        RETURN;
    END
    ELSE IF @p_entity_type = N'obligation-retention'
    BEGIN
        DECLARE @rt_retained_object     NVARCHAR(500) = JSON_VALUE(@p_payload, '$.retainedObject');
        DECLARE @rt_min_retention_value INT           = TRY_CAST(JSON_VALUE(@p_payload, '$.minRetentionValue') AS INT);
        DECLARE @rt_min_retention_unit  NVARCHAR(30)  = JSON_VALUE(@p_payload, '$.minRetentionUnit');
        DECLARE @rt_max_retention_value INT           = TRY_CAST(JSON_VALUE(@p_payload, '$.maxRetentionValue') AS INT);
        DECLARE @rt_max_retention_unit  NVARCHAR(30)  = JSON_VALUE(@p_payload, '$.maxRetentionUnit');
        DECLARE @rt_disposal_policy     NVARCHAR(500) = JSON_VALUE(@p_payload, '$.disposalPolicy');
        EXEC dbo.sp_cm_obligation_retention_save
             @p_id                  = @p_id,
             @p_obligation_id       = @obligation_id,
             @p_retained_object     = @rt_retained_object,
             @p_min_retention_value = @rt_min_retention_value,
             @p_min_retention_unit  = @rt_min_retention_unit,
             @p_max_retention_value = @rt_max_retention_value,
             @p_max_retention_unit  = @rt_max_retention_unit,
             @p_disposal_policy     = @rt_disposal_policy,
             @p_remarks             = @row_remarks,
             @p_status              = @row_status,
             @p_usr_id              = @p_usr_id;
        RETURN;
    END
    ELSE
        RAISERROR('cm_manage_obligation_taxonomy: unknown or unsupported entity_type %s for action %s.', 16, 1, @p_entity_type, @effective_action);
END
GO

PRINT '030 obligation taxonomy dispatcher (payload _action override) installed.';
GO
