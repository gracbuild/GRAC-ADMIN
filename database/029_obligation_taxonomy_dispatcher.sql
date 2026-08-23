-- =====================================================================
-- 029 -- Obligation Taxonomy (Phase 2B: dispatcher SPs)
--
-- Two dispatcher stored procedures that route the RepositoryController's
-- existing 'secure/query' and 'secure/manage' EntityType-based envelope
-- flow to the 17 typed sub-procs installed by 028.
--
-- Modeled on the existing bifurcation for assurance entities where the
-- service layer picks between:
--    dbo.cm_get_repository            (default)
--    dbo.cm_get_assurance_repository  (assurance-*)
--    dbo.cm_get_obligation_taxonomy   (obligation-* typed -- NEW here)
--
-- and:
--    dbo.cm_manage_repository            (default)
--    dbo.cm_manage_assurance_repository  (assurance-*)
--    dbo.cm_manage_obligation_taxonomy   (obligation-* typed -- NEW here)
--
-- The existing cm_manage_repository still owns the Obligation MASTER
-- (name, text, keywords, mappings).  These new dispatchers own the
-- TYPED DETAIL (state rule, execution spec, ..., evidence links).
--
-- Entity types (EntityType field the front-end / gateway sends):
--   obligation-types                -- GET only: list 7 types (dropdown)
--   obligation-state                -- GET / SAVE
--   obligation-execution            -- GET / SAVE
--   obligation-assurance            -- GET / SAVE
--   obligation-event-response       -- GET / SAVE
--   obligation-constraint           -- GET / SAVE
--   obligation-retention            -- GET / SAVE
--   obligation-evidence-links       -- GET / ATTACH / DETACH
--   obligation-type-assignment      -- SAVE only: set master.obligation_type_id
--
-- Actions accepted by the manage dispatcher:
--   SAVE            -- upsert a typed detail row  (also 'ATTACH' for evidence links)
--   DETACH          -- soft-detach an evidence link  (aliased by 'RETIRE'/'DELETE')
--   ASSIGN_TYPE     -- set obligation_type_id on the master row
--
-- Payload contract: JSON string in @p_payload.  All shapes require
-- obligationId (parent obligation identifier).  Additional fields per
-- entity_type:
--
--   obligation-state:            attribute, operator, value, unit, tolerance, remarks, status
--   obligation-execution:        action, executionFrequencyId, triggerCondition,
--                                responsibleParty, dueWithin, remarks, status
--   obligation-assurance:        verificationMethod, scope, assuranceFrequencyId,
--                                assuranceParty, remarks, status
--   obligation-event-response:   triggerEvent, responseAction, slaValue, slaUnit,
--                                escalationPath, remarks, status
--   obligation-constraint:       prohibitedCondition, scope, exceptionPolicy,
--                                remarks, status
--   obligation-retention:        retainedObject, minRetentionValue, minRetentionUnit,
--                                maxRetentionValue, maxRetentionUnit,
--                                disposalPolicy, remarks, status
--   obligation-evidence-links:   obligationEvidenceId, remarks
--   obligation-type-assignment:  typeCode
--
-- @p_id is the detail row id (0 for insert).  For type-assignment and
-- evidence-link ops, @p_id is ignored.
--
-- Preflight: 028 must be applied (sub-procs must exist).
--
-- Rollback: database/029_obligation_taxonomy_dispatcher_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.sp_cm_obligation_type_master_list','P') IS NULL
BEGIN
    RAISERROR('029 preflight failed: run 028 (typed sub-procs) before 029.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- cm_get_obligation_taxonomy
--   Entry point for READ-only calls under the obligation taxonomy area.
--   Signature mirrors cm_get_repository / cm_get_assurance_repository so
--   the service layer can route without knowing the underlying shape.
--
--   obligationId source: JSON_VALUE(@p_payload,'$.obligationId') takes
--   precedence; falls back to @p_id (the simpler front-end contract
--   when the URL already carries the obligation id).
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
-- cm_manage_obligation_taxonomy
--   Entry point for SAVE / DETACH / ASSIGN_TYPE calls under the
--   obligation taxonomy area.
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

    DECLARE @obligation_id BIGINT =
        TRY_CAST(JSON_VALUE(@p_payload, '$.obligationId') AS BIGINT);

    -- ------------------------------------------------------------------
    -- ASSIGN_TYPE:  set master.obligation_type_id via sub-proc.
    -- ------------------------------------------------------------------
    IF @p_entity_type = N'obligation-type-assignment'
       OR (@p_entity_type = N'obligation-types' AND @p_action = N'ASSIGN_TYPE')
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

        IF @p_action IN (N'ATTACH', N'SAVE')
            EXEC dbo.sp_cm_obligation_evidence_link_attach
                 @p_obligation_id          = @obligation_id,
                 @p_obligation_evidence_id = @obligation_evidence_id,
                 @p_remarks                = @link_remarks,
                 @p_usr_id                 = @p_usr_id;
        ELSE IF @p_action IN (N'DETACH', N'RETIRE', N'DELETE')
            EXEC dbo.sp_cm_obligation_evidence_link_detach
                 @p_obligation_id          = @obligation_id,
                 @p_obligation_evidence_id = @obligation_evidence_id,
                 @p_usr_id                 = @p_usr_id;
        ELSE
            RAISERROR('cm_manage_obligation_taxonomy: unsupported action %s for obligation-evidence-links.', 16, 1, @p_action);
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
        RAISERROR('cm_manage_obligation_taxonomy: unknown or unsupported entity_type %s for action %s.', 16, 1, @p_entity_type, @p_action);
END
GO

PRINT '029 obligation taxonomy dispatcher installed.';
GO
