-- =====================================================================
-- 028 -- Obligation Taxonomy (Phase 2A: typed detail procs)
--
-- Standalone stored procedures for the 7-type obligation taxonomy
-- introduced by 026 (schema) + 027 (data migration).
--
-- These procs DO NOT touch dbo.cm_manage_repository (the 3300+ line
-- dispatcher for obligation master read/write).  They are additive --
-- the existing master flow continues unchanged; the front-end / API
-- calls these procs separately to author the type-specific detail
-- and evidence-link data for an obligation.
--
-- Scope (17 procedures):
--   Type discovery (1):
--     sp_cm_obligation_type_master_list
--
--   Type assignment on master row (1):
--     sp_cm_obligation_type_assign
--
--   Per-type detail get / save (12 = 6 * 2):
--     sp_cm_obligation_state_get / _save
--     sp_cm_obligation_execution_get / _save
--     sp_cm_obligation_assurance_get / _save
--     sp_cm_obligation_event_response_get / _save
--     sp_cm_obligation_constraint_get / _save
--     sp_cm_obligation_retention_get / _save
--
--   Evidence links (3):
--     sp_cm_obligation_evidence_links_get    -- union across 6 link tables
--     sp_cm_obligation_evidence_link_attach  -- routes to right table by type
--     sp_cm_obligation_evidence_link_detach  -- soft delete (status='Inactive')
--
-- Maker-checker: NOT applied by these procs.  Writes are direct.
-- If sir wants typed-detail authoring to flow through change_management
-- like the master does, add a wrapper migration later.  This choice is
-- called out explicitly so it is not accidental.
--
-- Preflight: 026 must be applied (obligation_type_master + detail
-- tables + link tables must exist).
--
-- Rollback: database/028_obligation_typed_procs_rollback.sql
--
-- Safe to re-run (all procs use CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
BEGIN
    RAISERROR('028 preflight failed: run 026 (schema) before 028.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_cm_obligation_type_master_list
--   Returns the 7 active taxonomy types ordered by display_order.
--   UI uses this to populate the "Obligation Type" dropdown.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_type_master_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        t.obligation_type_id  AS Id,
        t.type_code           AS TypeCode,
        t.type_name           AS TypeName,
        t.description         AS Description,
        t.display_order       AS DisplayOrder,
        t.status              AS Status
    FROM GRAC_New.obligation_type_master t
    WHERE t.status = N'Active'
    ORDER BY t.display_order, t.type_name;
END
GO

-- =====================================================================
-- sp_cm_obligation_type_assign
--   Sets (or clears) obligation_type_id on a requirement_obligation row.
--   Pass @p_type_code = 'State' / 'Execution' / ... to assign, or
--   @p_type_code = '' (or NULL) to un-classify (set NULL).
--
--   Refuses to change type if type-specific detail rows already exist
--   under the OLD type -- caller must first detach them (safety net so
--   sir doesn't accidentally orphan State rules by re-typing an
--   obligation as Constraint).
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_type_assign
    @p_obligation_id BIGINT,
    @p_type_code     NVARCHAR(40) = NULL,
    @p_usr_id        NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52800, 'sp_cm_obligation_type_assign: @p_obligation_id required.', 1;

    IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation
                  WHERE obligation_id = @p_obligation_id)
        THROW 52801, 'sp_cm_obligation_type_assign: obligation not found.', 1;

    DECLARE @current_type_id BIGINT =
        (SELECT obligation_type_id FROM GRAC_New.requirement_obligation
         WHERE obligation_id = @p_obligation_id);

    DECLARE @new_type_id BIGINT = NULL;
    IF NULLIF(LTRIM(RTRIM(@p_type_code)), N'') IS NOT NULL
    BEGIN
        SELECT @new_type_id = obligation_type_id
        FROM GRAC_New.obligation_type_master
        WHERE type_code = @p_type_code AND status = N'Active';

        IF @new_type_id IS NULL
            THROW 52802, 'sp_cm_obligation_type_assign: unknown type_code.', 1;
    END

    -- Safety: block re-type when old-type details exist.
    IF @current_type_id IS NOT NULL
       AND @new_type_id IS NOT NULL
       AND @current_type_id <> @new_type_id
    BEGIN
        DECLARE @current_code NVARCHAR(40) =
            (SELECT type_code FROM GRAC_New.obligation_type_master
             WHERE obligation_type_id = @current_type_id);

        DECLARE @detail_count INT = 0;
        IF @current_code = N'State'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_state_rule
            WHERE obligation_id = @p_obligation_id AND status = N'Active';
        ELSE IF @current_code = N'Execution'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_execution_spec
            WHERE obligation_id = @p_obligation_id AND status = N'Active';
        ELSE IF @current_code = N'Assurance'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_assurance_spec
            WHERE obligation_id = @p_obligation_id AND status = N'Active';
        ELSE IF @current_code = N'EventResponse'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_event_response
            WHERE obligation_id = @p_obligation_id AND status = N'Active';
        ELSE IF @current_code = N'Constraint'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_constraint_rule
            WHERE obligation_id = @p_obligation_id AND status = N'Active';
        ELSE IF @current_code = N'Retention'
            SELECT @detail_count = COUNT(1) FROM GRAC_New.obligation_retention_spec
            WHERE obligation_id = @p_obligation_id AND status = N'Active';

        IF @detail_count > 0
            THROW 52803, 'sp_cm_obligation_type_assign: detach existing typed-detail rows before changing type.', 1;
    END

    UPDATE GRAC_New.requirement_obligation
    SET obligation_type_id = @new_type_id,
        updated_by = @p_usr_id,
        updated_dt = SYSUTCDATETIME()
    WHERE obligation_id = @p_obligation_id;

    SELECT @p_obligation_id AS ObligationId, @new_type_id AS ObligationTypeId;
END
GO

-- =====================================================================
-- Internal helper (inline, not a proc): verify obligation exists and
-- carries the expected type_code.  Used by every typed save proc.
-- Reproduced inline in each proc to keep the SPs self-contained.
-- =====================================================================

-- =====================================================================
-- sp_cm_obligation_state_get
--   List State rules for an obligation.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_state_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        r.state_rule_id     AS Id,
        r.obligation_id     AS ObligationId,
        r.attribute         AS Attribute,
        r.operator          AS Operator,
        r.value             AS [Value],
        r.unit              AS Unit,
        r.tolerance         AS Tolerance,
        r.remarks           AS Remarks,
        r.status            AS Status,
        r.entered_by        AS EnteredBy,
        r.entered_dt        AS EnteredDt,
        r.updated_by        AS UpdatedBy,
        r.updated_dt        AS UpdatedDt
    FROM GRAC_New.obligation_state_rule r
    WHERE r.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR r.status = N'Active')
    ORDER BY r.entered_dt DESC, r.state_rule_id DESC;
END
GO

-- =====================================================================
-- sp_cm_obligation_state_save
--   Insert (when @p_id = 0) or update a State rule for an obligation.
--   Refuses to write if obligation is not typed as 'State'.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_state_save
    @p_id            BIGINT       = 0,
    @p_obligation_id BIGINT,
    @p_attribute     NVARCHAR(250),
    @p_operator      NVARCHAR(30),
    @p_value         NVARCHAR(500),
    @p_unit          NVARCHAR(50)  = NULL,
    @p_tolerance     NVARCHAR(200) = NULL,
    @p_remarks       NVARCHAR(MAX) = NULL,
    @p_status        NVARCHAR(30)  = N'Active',
    @p_usr_id        NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52810, 'sp_cm_obligation_state_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_attribute)), N'') IS NULL
        THROW 52811, 'sp_cm_obligation_state_save: @p_attribute required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_operator)), N'') IS NULL
        THROW 52812, 'sp_cm_obligation_state_save: @p_operator required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_value)), N'') IS NULL
        THROW 52813, 'sp_cm_obligation_state_save: @p_value required.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'State')
        THROW 52814, 'sp_cm_obligation_state_save: obligation is not typed as State.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_state_rule(
            obligation_id, attribute, operator, [value], unit, tolerance,
            remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_attribute, @p_operator, @p_value, @p_unit, @p_tolerance,
               @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_state_rule
        SET attribute  = @p_attribute,
            operator   = @p_operator,
            [value]    = @p_value,
            unit       = @p_unit,
            tolerance  = @p_tolerance,
            remarks    = @p_remarks,
            status     = @p_status,
            updated_by = @p_usr_id,
            updated_dt = SYSUTCDATETIME()
        WHERE state_rule_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- sp_cm_obligation_execution_get / _save
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_execution_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        s.execution_spec_id       AS Id,
        s.obligation_id           AS ObligationId,
        s.action                  AS [Action],
        s.execution_frequency_id  AS ExecutionFrequencyId,
        freq.option_label         AS ExecutionFrequency,
        s.trigger_condition       AS TriggerCondition,
        s.responsible_party       AS ResponsibleParty,
        s.due_within              AS DueWithin,
        s.remarks                 AS Remarks,
        s.status                  AS Status,
        s.entered_by              AS EnteredBy,
        s.entered_dt              AS EnteredDt,
        s.updated_by              AS UpdatedBy,
        s.updated_dt              AS UpdatedDt
    FROM GRAC_New.obligation_execution_spec s
    LEFT JOIN GRAC_New.reference_option freq
        ON freq.reference_option_id = s.execution_frequency_id
    WHERE s.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR s.status = N'Active')
    ORDER BY s.entered_dt DESC, s.execution_spec_id DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_execution_save
    @p_id                     BIGINT       = 0,
    @p_obligation_id          BIGINT,
    @p_action                 NVARCHAR(1000),
    @p_execution_frequency_id BIGINT       = NULL,
    @p_trigger_condition      NVARCHAR(500) = NULL,
    @p_responsible_party      NVARCHAR(250) = NULL,
    @p_due_within             NVARCHAR(120) = NULL,
    @p_remarks                NVARCHAR(MAX) = NULL,
    @p_status                 NVARCHAR(30)  = N'Active',
    @p_usr_id                 NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52820, 'sp_cm_obligation_execution_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_action)), N'') IS NULL
        THROW 52821, 'sp_cm_obligation_execution_save: @p_action required.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'Execution')
        THROW 52822, 'sp_cm_obligation_execution_save: obligation is not typed as Execution.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_execution_spec(
            obligation_id, [action], execution_frequency_id, trigger_condition,
            responsible_party, due_within, remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_action, @p_execution_frequency_id, @p_trigger_condition,
               @p_responsible_party, @p_due_within, @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_execution_spec
        SET [action]                = @p_action,
            execution_frequency_id  = @p_execution_frequency_id,
            trigger_condition       = @p_trigger_condition,
            responsible_party       = @p_responsible_party,
            due_within              = @p_due_within,
            remarks                 = @p_remarks,
            status                  = @p_status,
            updated_by              = @p_usr_id,
            updated_dt              = SYSUTCDATETIME()
        WHERE execution_spec_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- sp_cm_obligation_assurance_get / _save
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

-- =====================================================================
-- sp_cm_obligation_event_response_get / _save
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_event_response_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.event_response_id  AS Id,
        e.obligation_id      AS ObligationId,
        e.trigger_event      AS TriggerEvent,
        e.response_action    AS ResponseAction,
        e.sla_value          AS SlaValue,
        e.sla_unit           AS SlaUnit,
        e.escalation_path    AS EscalationPath,
        e.remarks            AS Remarks,
        e.status             AS Status,
        e.entered_by         AS EnteredBy,
        e.entered_dt         AS EnteredDt,
        e.updated_by         AS UpdatedBy,
        e.updated_dt         AS UpdatedDt
    FROM GRAC_New.obligation_event_response e
    WHERE e.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR e.status = N'Active')
    ORDER BY e.entered_dt DESC, e.event_response_id DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_event_response_save
    @p_id              BIGINT       = 0,
    @p_obligation_id   BIGINT,
    @p_trigger_event   NVARCHAR(500),
    @p_response_action NVARCHAR(1000),
    @p_sla_value       INT           = NULL,
    @p_sla_unit        NVARCHAR(30)  = NULL,
    @p_escalation_path NVARCHAR(500) = NULL,
    @p_remarks         NVARCHAR(MAX) = NULL,
    @p_status          NVARCHAR(30)  = N'Active',
    @p_usr_id          NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52840, 'sp_cm_obligation_event_response_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_trigger_event)), N'') IS NULL
        THROW 52841, 'sp_cm_obligation_event_response_save: @p_trigger_event required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_response_action)), N'') IS NULL
        THROW 52842, 'sp_cm_obligation_event_response_save: @p_response_action required.', 1;
    IF @p_sla_unit IS NOT NULL
       AND @p_sla_unit NOT IN (N'Hours', N'Days', N'Weeks', N'Months', N'Years')
        THROW 52843, 'sp_cm_obligation_event_response_save: invalid @p_sla_unit.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'EventResponse')
        THROW 52844, 'sp_cm_obligation_event_response_save: obligation is not typed as EventResponse.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_event_response(
            obligation_id, trigger_event, response_action, sla_value, sla_unit,
            escalation_path, remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_trigger_event, @p_response_action, @p_sla_value, @p_sla_unit,
               @p_escalation_path, @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_event_response
        SET trigger_event    = @p_trigger_event,
            response_action  = @p_response_action,
            sla_value        = @p_sla_value,
            sla_unit         = @p_sla_unit,
            escalation_path  = @p_escalation_path,
            remarks          = @p_remarks,
            status           = @p_status,
            updated_by       = @p_usr_id,
            updated_dt       = SYSUTCDATETIME()
        WHERE event_response_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- sp_cm_obligation_constraint_get / _save
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_constraint_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        c.constraint_rule_id   AS Id,
        c.obligation_id        AS ObligationId,
        c.prohibited_condition AS ProhibitedCondition,
        c.scope                AS Scope,
        c.exception_policy     AS ExceptionPolicy,
        c.remarks              AS Remarks,
        c.status               AS Status,
        c.entered_by           AS EnteredBy,
        c.entered_dt           AS EnteredDt,
        c.updated_by           AS UpdatedBy,
        c.updated_dt           AS UpdatedDt
    FROM GRAC_New.obligation_constraint_rule c
    WHERE c.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR c.status = N'Active')
    ORDER BY c.entered_dt DESC, c.constraint_rule_id DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_constraint_save
    @p_id                   BIGINT       = 0,
    @p_obligation_id        BIGINT,
    @p_prohibited_condition NVARCHAR(1000),
    @p_scope                NVARCHAR(500) = NULL,
    @p_exception_policy     NVARCHAR(500) = NULL,
    @p_remarks              NVARCHAR(MAX) = NULL,
    @p_status               NVARCHAR(30)  = N'Active',
    @p_usr_id               NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52850, 'sp_cm_obligation_constraint_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_prohibited_condition)), N'') IS NULL
        THROW 52851, 'sp_cm_obligation_constraint_save: @p_prohibited_condition required.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'Constraint')
        THROW 52852, 'sp_cm_obligation_constraint_save: obligation is not typed as Constraint.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_constraint_rule(
            obligation_id, prohibited_condition, scope, exception_policy,
            remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_prohibited_condition, @p_scope, @p_exception_policy,
               @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_constraint_rule
        SET prohibited_condition = @p_prohibited_condition,
            scope                = @p_scope,
            exception_policy     = @p_exception_policy,
            remarks              = @p_remarks,
            status               = @p_status,
            updated_by           = @p_usr_id,
            updated_dt           = SYSUTCDATETIME()
        WHERE constraint_rule_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- sp_cm_obligation_retention_get / _save
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_retention_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        r.retention_spec_id    AS Id,
        r.obligation_id        AS ObligationId,
        r.retained_object      AS RetainedObject,
        r.min_retention_value  AS MinRetentionValue,
        r.min_retention_unit   AS MinRetentionUnit,
        r.max_retention_value  AS MaxRetentionValue,
        r.max_retention_unit   AS MaxRetentionUnit,
        r.disposal_policy      AS DisposalPolicy,
        r.remarks              AS Remarks,
        r.status               AS Status,
        r.entered_by           AS EnteredBy,
        r.entered_dt           AS EnteredDt,
        r.updated_by           AS UpdatedBy,
        r.updated_dt           AS UpdatedDt
    FROM GRAC_New.obligation_retention_spec r
    WHERE r.obligation_id = @p_obligation_id
      AND (@p_include_inactive = 1 OR r.status = N'Active')
    ORDER BY r.entered_dt DESC, r.retention_spec_id DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_retention_save
    @p_id                  BIGINT       = 0,
    @p_obligation_id       BIGINT,
    @p_retained_object     NVARCHAR(500),
    @p_min_retention_value INT           = NULL,
    @p_min_retention_unit  NVARCHAR(30)  = NULL,
    @p_max_retention_value INT           = NULL,
    @p_max_retention_unit  NVARCHAR(30)  = NULL,
    @p_disposal_policy     NVARCHAR(500) = NULL,
    @p_remarks             NVARCHAR(MAX) = NULL,
    @p_status              NVARCHAR(30)  = N'Active',
    @p_usr_id              NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52860, 'sp_cm_obligation_retention_save: @p_obligation_id required.', 1;
    IF NULLIF(LTRIM(RTRIM(@p_retained_object)), N'') IS NULL
        THROW 52861, 'sp_cm_obligation_retention_save: @p_retained_object required.', 1;
    IF @p_min_retention_unit IS NOT NULL
       AND @p_min_retention_unit NOT IN (N'Days', N'Weeks', N'Months', N'Years')
        THROW 52862, 'sp_cm_obligation_retention_save: invalid @p_min_retention_unit.', 1;
    IF @p_max_retention_unit IS NOT NULL
       AND @p_max_retention_unit NOT IN (N'Days', N'Weeks', N'Months', N'Years')
        THROW 52863, 'sp_cm_obligation_retention_save: invalid @p_max_retention_unit.', 1;

    IF NOT EXISTS(
        SELECT 1 FROM GRAC_New.requirement_obligation ro
        JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
        WHERE ro.obligation_id = @p_obligation_id AND t.type_code = N'Retention')
        THROW 52864, 'sp_cm_obligation_retention_save: obligation is not typed as Retention.', 1;

    DECLARE @new_id BIGINT = @p_id;
    IF ISNULL(@p_id, 0) = 0
    BEGIN
        INSERT INTO GRAC_New.obligation_retention_spec(
            obligation_id, retained_object, min_retention_value, min_retention_unit,
            max_retention_value, max_retention_unit, disposal_policy,
            remarks, status, entered_by
        )
        VALUES(@p_obligation_id, @p_retained_object, @p_min_retention_value, @p_min_retention_unit,
               @p_max_retention_value, @p_max_retention_unit, @p_disposal_policy,
               @p_remarks, @p_status, @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE GRAC_New.obligation_retention_spec
        SET retained_object     = @p_retained_object,
            min_retention_value = @p_min_retention_value,
            min_retention_unit  = @p_min_retention_unit,
            max_retention_value = @p_max_retention_value,
            max_retention_unit  = @p_max_retention_unit,
            disposal_policy     = @p_disposal_policy,
            remarks             = @p_remarks,
            status              = @p_status,
            updated_by          = @p_usr_id,
            updated_dt          = SYSUTCDATETIME()
        WHERE retention_spec_id = @p_id AND obligation_id = @p_obligation_id;
    END

    SELECT @new_id AS Id;
END
GO

-- =====================================================================
-- sp_cm_obligation_evidence_links_get
--   Returns a UNIONed view of evidence links across all six link tables
--   for an obligation, joined to requirement_obligation_evidence and
--   evidence_type_master so the UI can render "who is attached where".
--
--   TypeCode column identifies which link table each row came from.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_evidence_links_get
    @p_obligation_id BIGINT,
    @p_include_inactive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    ;WITH lnk AS (
        SELECT N'State' AS TypeCode, l.state_evidence_link_id AS LinkId,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_state_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
        UNION ALL
        SELECT N'Execution', l.execution_evidence_link_id,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_execution_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
        UNION ALL
        SELECT N'Assurance', l.assurance_evidence_link_id,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_assurance_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
        UNION ALL
        SELECT N'EventResponse', l.event_response_evidence_link_id,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_event_response_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
        UNION ALL
        SELECT N'Constraint', l.constraint_evidence_link_id,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_constraint_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
        UNION ALL
        SELECT N'Retention', l.retention_evidence_link_id,
               l.obligation_id, l.obligation_evidence_id, l.remarks, l.status,
               l.entered_by, l.entered_dt, l.updated_by, l.updated_dt
        FROM GRAC_New.obligation_retention_evidence_link l
        WHERE l.obligation_id = @p_obligation_id
    )
    SELECT
        lnk.TypeCode                  AS TypeCode,
        lnk.LinkId                    AS LinkId,
        lnk.obligation_id             AS ObligationId,
        lnk.obligation_evidence_id    AS ObligationEvidenceId,
        et.evidence_type_id           AS EvidenceTypeId,
        et.evidence_type_name         AS EvidenceType,
        freq.reference_option_id      AS FrequencyId,
        freq.option_label             AS Frequency,
        e.retention_requirement       AS RetentionRequirement,
        e.remarks                     AS EvidenceRemarks,
        lnk.remarks                   AS LinkRemarks,
        lnk.status                    AS Status,
        lnk.entered_by                AS EnteredBy,
        lnk.entered_dt                AS EnteredDt,
        lnk.updated_by                AS UpdatedBy,
        lnk.updated_dt                AS UpdatedDt
    FROM lnk
    LEFT JOIN GRAC_New.requirement_obligation_evidence e
        ON e.obligation_evidence_id = lnk.obligation_evidence_id
    LEFT JOIN GRAC_New.evidence_type_master et
        ON et.evidence_type_id = e.evidence_type_id
    LEFT JOIN GRAC_New.reference_option freq
        ON freq.reference_option_id = e.frequency_id
    WHERE (@p_include_inactive = 1 OR lnk.status = N'Active')
    ORDER BY lnk.TypeCode, COALESCE(et.display_order, 999), et.evidence_type_name;
END
GO

-- =====================================================================
-- sp_cm_obligation_evidence_link_attach
--   Inserts a link row into the correct per-type link table based on
--   the obligation's current obligation_type_id.  Fails if the
--   obligation is un-typed.  If the (obligation, evidence) active pair
--   already exists in that table, is a no-op.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_evidence_link_attach
    @p_obligation_id          BIGINT,
    @p_obligation_evidence_id BIGINT,
    @p_remarks                NVARCHAR(500) = NULL,
    @p_usr_id                 NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52870, 'sp_cm_obligation_evidence_link_attach: @p_obligation_id required.', 1;
    IF @p_obligation_evidence_id IS NULL OR @p_obligation_evidence_id <= 0
        THROW 52871, 'sp_cm_obligation_evidence_link_attach: @p_obligation_evidence_id required.', 1;

    DECLARE @type_code NVARCHAR(40) =
        (SELECT t.type_code
         FROM GRAC_New.requirement_obligation ro
         JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
         WHERE ro.obligation_id = @p_obligation_id);

    IF @type_code IS NULL
        THROW 52872, 'sp_cm_obligation_evidence_link_attach: obligation is un-typed. Assign a type first via sp_cm_obligation_type_assign.', 1;

    IF NOT EXISTS(SELECT 1 FROM GRAC_New.requirement_obligation_evidence
                  WHERE obligation_evidence_id = @p_obligation_evidence_id)
        THROW 52873, 'sp_cm_obligation_evidence_link_attach: evidence spec not found.', 1;

    IF @type_code = N'State'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_state_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_state_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'Execution'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_execution_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_execution_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'Assurance'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_assurance_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_assurance_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'EventResponse'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_event_response_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_event_response_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'Constraint'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_constraint_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_constraint_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'Retention'
    BEGIN
        IF NOT EXISTS(SELECT 1 FROM GRAC_New.obligation_retention_evidence_link
                      WHERE obligation_id = @p_obligation_id
                        AND obligation_evidence_id = @p_obligation_evidence_id
                        AND status = N'Active')
            INSERT INTO GRAC_New.obligation_retention_evidence_link(obligation_id, obligation_evidence_id, remarks, status, entered_by)
            VALUES(@p_obligation_id, @p_obligation_evidence_id, @p_remarks, N'Active', @p_usr_id);
    END
    ELSE IF @type_code = N'Evidence'
        THROW 52874, 'sp_cm_obligation_evidence_link_attach: standalone Evidence obligations do not use link tables -- evidence is attached directly via requirement_obligation_evidence.obligation_id.', 1;
    ELSE
        THROW 52875, 'sp_cm_obligation_evidence_link_attach: unknown obligation type_code.', 1;

    SELECT @p_obligation_id AS ObligationId, @p_obligation_evidence_id AS ObligationEvidenceId, @type_code AS TypeCode;
END
GO

-- =====================================================================
-- sp_cm_obligation_evidence_link_detach
--   Soft-detach: sets status='Inactive' on the link row in the correct
--   per-type link table.  Uses the obligation's type_code to route.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.sp_cm_obligation_evidence_link_detach
    @p_obligation_id          BIGINT,
    @p_obligation_evidence_id BIGINT,
    @p_usr_id                 NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    IF @p_obligation_id IS NULL OR @p_obligation_id <= 0
        THROW 52880, 'sp_cm_obligation_evidence_link_detach: @p_obligation_id required.', 1;
    IF @p_obligation_evidence_id IS NULL OR @p_obligation_evidence_id <= 0
        THROW 52881, 'sp_cm_obligation_evidence_link_detach: @p_obligation_evidence_id required.', 1;

    DECLARE @type_code NVARCHAR(40) =
        (SELECT t.type_code
         FROM GRAC_New.requirement_obligation ro
         JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = ro.obligation_type_id
         WHERE ro.obligation_id = @p_obligation_id);

    IF @type_code IS NULL
        THROW 52882, 'sp_cm_obligation_evidence_link_detach: obligation is un-typed.', 1;

    IF @type_code = N'State'
        UPDATE GRAC_New.obligation_state_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'Execution'
        UPDATE GRAC_New.obligation_execution_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'Assurance'
        UPDATE GRAC_New.obligation_assurance_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'EventResponse'
        UPDATE GRAC_New.obligation_event_response_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'Constraint'
        UPDATE GRAC_New.obligation_constraint_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'Retention'
        UPDATE GRAC_New.obligation_retention_evidence_link
        SET status = N'Inactive', updated_by = @p_usr_id, updated_dt = SYSUTCDATETIME()
        WHERE obligation_id = @p_obligation_id AND obligation_evidence_id = @p_obligation_evidence_id AND status = N'Active';
    ELSE IF @type_code = N'Evidence'
        THROW 52883, 'sp_cm_obligation_evidence_link_detach: standalone Evidence obligations use requirement_obligation_evidence.obligation_id directly.', 1;
    ELSE
        THROW 52884, 'sp_cm_obligation_evidence_link_detach: unknown obligation type_code.', 1;

    SELECT @@ROWCOUNT AS DetachedCount;
END
GO

PRINT '028 obligation typed procs installed (17 procedures).';
GO
